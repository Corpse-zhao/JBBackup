//
//  JBBZip.m
//

#import "JBBZip.h"
#import "JBBCommon.h"
#include <zlib.h>

#pragma mark - 小工具

static void JBBNeed(NSString **err, NSString *msg) {
	if (err) *err = msg;
}

// ZIP 一律小端
static void JBBW8(FILE *f, uint8_t v) { fputc(v, f); }
static void JBBW16(FILE *f, uint16_t v) { JBBW8(f, (uint8_t)(v & 0xFF)); JBBW8(f, (uint8_t)(v >> 8)); }
static void JBBW32(FILE *f, uint32_t v) {
	JBBW8(f, (uint8_t)(v & 0xFF));         JBBW8(f, (uint8_t)((v >> 8) & 0xFF));
	JBBW8(f, (uint8_t)((v >> 16) & 0xFF)); JBBW8(f, (uint8_t)((v >> 24) & 0xFF));
}

static uint16_t JBBR16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t JBBR32(const uint8_t *p) {
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
	     | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void JBBDosTime(time_t t, uint16_t *outTime, uint16_t *outDate) {
	struct tm tmv;
	memset(&tmv, 0, sizeof(tmv));
	localtime_r(&t, &tmv);
	int year = tmv.tm_year + 1900;
	if (year < 1980) year = 1980;
	if (year > 2107) year = 2107;
	*outTime = (uint16_t)(((tmv.tm_hour & 0x1F) << 11) | ((tmv.tm_min & 0x3F) << 5) | ((tmv.tm_sec / 2) & 0x1F));
	*outDate = (uint16_t)((((year - 1980) & 0x7F) << 9) | (((tmv.tm_mon + 1) & 0x0F) << 5) | (tmv.tm_mday & 0x1F));
}

static BOOL JBBWriteAll(FILE *f, const void *buf, size_t n) {
	if (n == 0) return YES;
	return fwrite(buf, 1, n, f) == n;
}

#pragma mark - 路径安全（Zip Slip）

/// 把归档内的条目名安全地拼到 base 下。任何可疑条目一律返回 nil（拒绝，不做「消解」）。
///
/// ⚠️ 这是必须的：恶意/损坏的 zip 可以用 `../../Library/Preferences/x.plist` 这样的条目名
///    把文件写到目标目录之外（Zip Slip）。本 App 是 no-sandbox 且备份会被自动还原，
///    一旦不防就等于给了个「任意文件写」的口子。
static NSString *JBBSafeJoin(NSString *base, NSString *entry) {
	if (!base.length || !entry.length) return nil;
	if ([entry hasPrefix:@"/"] || [entry hasPrefix:@"\\"]) return nil;      // 绝对路径
	NSString *norm = [entry stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
	NSMutableArray<NSString *> *parts = [NSMutableArray array];
	for (NSString *seg in [norm componentsSeparatedByString:@"/"]) {
		if (!seg.length || [seg isEqualToString:@"."]) continue;
		if ([seg isEqualToString:@".."]) return nil;                        // 上跳 → 直接拒
		if ([seg rangeOfString:@":"].location != NSNotFound) return nil;    // 排除 a:b 之类怪东西
		[parts addObject:seg];
	}
	if (!parts.count) return nil;
	NSString *out = base;
	for (NSString *seg in parts) out = [out stringByAppendingPathComponent:seg];
	NSString *prefix = [base hasSuffix:@"/"] ? base : [base stringByAppendingString:@"/"];
	if (![out hasPrefix:prefix]) return nil;                                // 双保险
	return out;
}

/// 归档条目名 → 需要创建的目录链（并返回它是不是目录条目）
static BOOL JBBEnsureParentOf(NSString *filePath) {
	return JBBEnsureDir([filePath stringByDeletingLastPathComponent]);
}

#pragma mark - 打包

/// 递归列出目录下所有条目（含目录本身，这样空目录也能被还原）
static NSArray<NSDictionary *> *JBBCollectTree(NSString *root) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
	NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
	for (NSString *rel in en) {
		NSString *abs = [root stringByAppendingPathComponent:rel];
		NSDictionary *attr = [fm attributesOfItemAtPath:abs error:NULL];
		NSString *type = attr[NSFileType];
		BOOL isDir = [type isEqualToString:NSFileTypeDirectory];
		BOOL isFile = [type isEqualToString:NSFileTypeRegular];
		BOOL isLink = [type isEqualToString:NSFileTypeSymbolicLink];
		if (!isDir && !isFile && !isLink) continue;      // 跳过 socket/fifo 等
		[out addObject:@{
			@"rel": rel,
			@"abs": abs,
			@"dir": @(isDir),
			@"link": @(isLink),
			@"mode": @([attr[NSFilePosixPermissions] unsignedShortValue]),
		}];
	}
	return out;
}

/// 流式 deflate：读 in → 写 out。返回是否成功，并回填 crc / csize / usize。
static BOOL JBBDeflateStream(FILE *fin, FILE *fout,
							 uint32_t *outCrc, uint32_t *outCsize, uint64_t *outUsize) {
	z_stream zs;
	memset(&zs, 0, sizeof(zs));
	if (deflateInit2(&zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
					 Z_DEFAULT_STRATEGY) != Z_OK) {
		return NO;
	}
	unsigned char inBuf[65536];
	unsigned char outBuf[65536];
	uLong crc = crc32(0L, Z_NULL, 0);
	uint64_t usize = 0;
	uint64_t csize = 0;
	BOOL ok = YES;

	zs.next_out = outBuf;
	zs.avail_out = (uInt)sizeof(outBuf);

	size_t n = 0;
	while ((n = fread(inBuf, 1, sizeof(inBuf), fin)) > 0) {
		crc = crc32(crc, inBuf, (uInt)n);
		usize += n;
		zs.next_in = inBuf;
		zs.avail_in = (uInt)n;
		while (zs.avail_in > 0) {
			if (deflate(&zs, Z_NO_FLUSH) != Z_OK) { ok = NO; break; }
			if (zs.avail_out == 0) {
				if (!JBBWriteAll(fout, outBuf, sizeof(outBuf))) { ok = NO; break; }
				csize += sizeof(outBuf);
				zs.next_out = outBuf;
				zs.avail_out = (uInt)sizeof(outBuf);
			}
		}
		if (!ok) break;
	}
	if (ok) {
		for (;;) {
			int r = deflate(&zs, Z_FINISH);
			size_t produced = sizeof(outBuf) - zs.avail_out;
			if (produced) {
				if (!JBBWriteAll(fout, outBuf, produced)) { ok = NO; break; }
				csize += produced;
				zs.next_out = outBuf;
				zs.avail_out = (uInt)sizeof(outBuf);
			}
			if (r == Z_STREAM_END) break;
			if (r != Z_OK) { ok = NO; break; }
		}
	}
	deflateEnd(&zs);
	if (outCrc) *outCrc = (uint32_t)crc;
	if (outCsize) *outCsize = (uint32_t)csize;
	if (outUsize) *outUsize = usize;
	return ok;
}

@implementation JBBZip

+ (unsigned long long)createZipAtPath:(NSString *)zipPath
						fromDirectory:(NSString *)dir
								error:(NSString **)err {
	if (!zipPath.length || !dir.length) { JBBNeed(err, @"参数为空"); return 0; }
	BOOL isDir = NO;
	if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
		JBBNeed(err, [NSString stringWithFormat:@"目录不存在：%@", dir]);
		return 0;
	}
	if (!JBBEnsureParentOf(zipPath)) { JBBNeed(err, @"无法创建 zip 的父目录"); return 0; }

	NSString *prefix = [dir lastPathComponent];
	NSArray<NSDictionary *> *items = JBBCollectTree(dir);
	JBBLog(@"打包 zip：%lu 个条目 → %@", (unsigned long)items.count, zipPath);

	FILE *f = fopen([zipPath fileSystemRepresentation], "wb");
	if (!f) { JBBNeed(err, @"打不开输出文件（磁盘满或没权限）"); return 0; }

	NSMutableData *central = [NSMutableData data];
	NSUInteger entryCount = 0;
	uint16_t dosTime = 0, dosDate = 0;
	JBBDosTime(time(NULL), &dosTime, &dosDate);
	BOOL ok = YES;

	for (NSDictionary *it in items) {
		NSString *rel = it[@"rel"];
		BOOL isDirEntry = [it[@"dir"] boolValue];
		uint16_t mode = (uint16_t)[it[@"mode"] unsignedShortValue];
		if (mode == 0) mode = isDirEntry ? 0755 : 0644;

		NSString *name = [NSString stringWithFormat:@"%@/%@", prefix, rel];
		if (isDirEntry) name = [name stringByAppendingString:@"/"];
		NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
		if (!nameData.length || nameData.length > 0xFFFF) { ok = NO; break; }

		long localOffset = ftell(f);

		uint32_t crc = 0, csize = 0;
		uint64_t usize = 0;
		uint16_t method = 0;

		// 先写 local header（crc/csize/usize 留空，写完数据回头 patch）
		JBBW32(f, 0x04034b50);
		JBBW16(f, 20);                       // version needed (2.0)
		JBBW16(f, 0x0800);                   // flags：文件名是 UTF-8
		JBBW16(f, 8);                        // method 稍后 patch 成实际值
		JBBW16(f, dosTime);
		JBBW16(f, dosDate);
		JBBW32(f, 0);                        // crc
		JBBW32(f, 0);                        // csize
		JBBW32(f, 0);                        // usize
		JBBW16(f, (uint16_t)nameData.length);
		JBBW16(f, 0);                        // extra len
		if (!JBBWriteAll(f, nameData.bytes, nameData.length)) { ok = NO; break; }

		if (isDirEntry) {
			method = 0;
		} else {
			FILE *fin = fopen([it[@"abs"] fileSystemRepresentation], "rb");
			if (!fin) {
				// 单个文件读不了不该毁掉整个备份：退化成空文件并继续
				JBBLog(@"跳过读不了的文件：%@", it[@"abs"]);
				method = 0;
			} else {
				method = 8;
				if (!JBBDeflateStream(fin, f, &crc, &csize, &usize)) {
					fclose(fin);
					ok = NO;
					break;
				}
				fclose(fin);
			}
		}
		long afterData = ftell(f);

		// 回填 local header 的 crc / csize / usize / method
		if (fseek(f, localOffset + 8, SEEK_SET) != 0) { ok = NO; break; }
		JBBW16(f, method);
		JBBW16(f, dosTime);
		JBBW16(f, dosDate);
		JBBW32(f, crc);
		JBBW32(f, csize);
		JBBW32(f, (uint32_t)usize);
		if (fseek(f, afterData, SEEK_SET) != 0) { ok = NO; break; }

		// central directory entry
		uint8_t hdr[46];
		memset(hdr, 0, sizeof(hdr));
		hdr[0] = 0x50; hdr[1] = 0x4b; hdr[2] = 0x01; hdr[3] = 0x02;   // 0x02014b50
		hdr[4] = 20; hdr[5] = 0;                                       // version made by
		hdr[6] = 20; hdr[7] = 0;                                       // version needed
		hdr[8] = 0x00; hdr[9] = 0x08;                                  // flags (UTF-8)
		hdr[10] = (uint8_t)(method & 0xFF); hdr[11] = (uint8_t)(method >> 8);
		hdr[12] = (uint8_t)(dosTime & 0xFF); hdr[13] = (uint8_t)(dosTime >> 8);
		hdr[14] = (uint8_t)(dosDate & 0xFF); hdr[15] = (uint8_t)(dosDate >> 8);
		memcpy(hdr + 16, &crc, 4);
		memcpy(hdr + 20, &csize, 4);
		uint32_t usize32 = (uint32_t)usize;
		memcpy(hdr + 24, &usize32, 4);
		hdr[28] = (uint8_t)(nameData.length & 0xFF); hdr[29] = (uint8_t)(nameData.length >> 8);
		// 30,31 = extra len = 0 ; 32,33 = comment len = 0 ; 34,35 = disk ; 36,37 = int attr = 0
		uint32_t eattr = (uint32_t)((mode & 0xFFFF) << 16);            // 保留 unix 权限位
		memcpy(hdr + 38, &eattr, 4);
		uint32_t lo = (uint32_t)localOffset;
		memcpy(hdr + 42, &lo, 4);
		[central appendBytes:hdr length:sizeof(hdr)];
		[central appendData:nameData];
		entryCount++;
	}

	if (ok) {
		long cdOffset = ftell(f);
		if (!JBBWriteAll(f, central.bytes, central.length)) ok = NO;
		if (ok) {
			JBBW32(f, 0x06054b50);
			JBBW16(f, 0); JBBW16(f, 0);
			JBBW16(f, (uint16_t)entryCount); JBBW16(f, (uint16_t)entryCount);
			JBBW32(f, (uint32_t)central.length);
			JBBW32(f, (uint32_t)cdOffset);
			JBBW16(f, 0);                                            // comment len
		}
	}

	long total = ftell(f);
	fclose(f);

	if (!ok) {
		[[NSFileManager defaultManager] removeItemAtPath:zipPath error:NULL];
		JBBNeed(err, @"写入 zip 过程中失败（磁盘满？）");
		return 0;
	}
	JBBLog(@"打包完成：%@（%lu 条目，%@）", zipPath, (unsigned long)entryCount,
		   JBBHumanSize((unsigned long long)(total > 0 ? total : 0)));
	return (unsigned long long)(total > 0 ? total : 0);
}

#pragma mark - 解包（zip）

/// 把 zs 当前已有的输入尽量解出来写进 f，crc/size 用调用方传进来的累加器。
///
/// ⚠️ crc/size 必须由**调用方**持有：上一版这个函数每次调用都从 0 重算，
///    而 deflate 数据是分块喂进去的 → 每块都会把前面算的 CRC 覆盖掉。
///    症状是「大文件 CRC 一直校验不过」，而小于一块的文件却正常，极难查。
/// @return 0=出错 1=输入吃完了（还要继续喂） 2=流已结束
static int JBBInflatePump(z_stream *zs, FILE *f, uLong *crcIO, uint64_t *sizeIO) {
	unsigned char buf[65536];
	for (;;) {
		zs->next_out = buf;
		zs->avail_out = (uInt)sizeof(buf);
		int r = inflate(zs, Z_NO_FLUSH);
		size_t produced = sizeof(buf) - zs->avail_out;
		if (produced) {
			*crcIO = crc32(*crcIO, buf, (uInt)produced);
			if (!JBBWriteAll(f, buf, produced)) return 0;
			*sizeIO += produced;
		}
		if (r == Z_STREAM_END) return 2;
		if (r != Z_OK && r != Z_BUF_ERROR) return 0;
		if (zs->avail_in == 0) return 1;              // 等下一块输入
		if (r == Z_BUF_ERROR && produced == 0) return 0;
	}
}

+ (NSUInteger)extractZipAtPath:(NSString *)zipPath
				   toDirectory:(NSString *)dir
						 error:(NSString **)err {
	if (!zipPath.length || !dir.length) { JBBNeed(err, @"参数为空"); return 0; }
	if (!JBBEnsureDir(dir)) { JBBNeed(err, @"目标目录建不出来"); return 0; }

	FILE *f = fopen([zipPath fileSystemRepresentation], "rb");
	if (!f) { JBBNeed(err, [NSString stringWithFormat:@"打不开文件：%@", zipPath]); return 0; }

	// 1. 从文件尾往前找 EOCD（0x06054b50），最多回退 64KB + 注释上限
	if (fseek(f, 0, SEEK_END) != 0) { fclose(f); JBBNeed(err, @"seek 失败"); return 0; }
	long fileSize = ftell(f);
	long back = fileSize < 70000 ? fileSize : 70000;
	NSMutableData *tail = [NSMutableData dataWithLength:(NSUInteger)back];
	if (fseek(f, fileSize - back, SEEK_SET) != 0
		|| fread(tail.mutableBytes, 1, (NSUInteger)back, f) != (NSUInteger)back) {
		fclose(f);
		JBBNeed(err, @"读文件尾失败");
		return 0;
	}
	const uint8_t *tp = tail.bytes;
	long eocd = -1;
	for (long i = back - 22; i >= 0; i--) {
		if (tp[i] == 0x50 && tp[i + 1] == 0x4b && tp[i + 2] == 0x05 && tp[i + 3] == 0x06) {
			eocd = i;
			break;
		}
	}
	if (eocd < 0) { fclose(f); JBBNeed(err, @"这不像是一个 ZIP 文件（找不到中央目录）"); return 0; }

	uint16_t count = JBBR16(tp + eocd + 10);
	uint32_t cdSize = JBBR32(tp + eocd + 12);
	uint32_t cdOffset = JBBR32(tp + eocd + 16);

	// 2. 读中央目录
	if (cdSize == 0 || cdSize > 64u * 1024u * 1024u) {
		fclose(f);
		JBBNeed(err, @"中央目录大小不合理（文件可能损坏）");
		return 0;
	}
	NSMutableData *cd = [NSMutableData dataWithLength:cdSize];
	if (fseek(f, (long)cdOffset, SEEK_SET) != 0
		|| fread(cd.mutableBytes, 1, cdSize, f) != cdSize) {
		fclose(f);
		JBBNeed(err, @"读中央目录失败");
		return 0;
	}

	// 3. 逐个解出来
	const uint8_t *cp = cd.bytes;
	NSUInteger pos = 0, files = 0, skipped = 0;
	BOOL fatal = NO;

	for (uint16_t i = 0; i < count && !fatal; i++) {
		if (pos + 46 > cdSize) { fatal = YES; break; }
		if (!(cp[pos] == 0x50 && cp[pos + 1] == 0x4b && cp[pos + 2] == 0x01 && cp[pos + 3] == 0x02)) {
			fatal = YES;
			break;
		}
		uint16_t method = JBBR16(cp + pos + 10);
		uint32_t crc = JBBR32(cp + pos + 16);
		uint32_t csize = JBBR32(cp + pos + 20);
		uint32_t usize = JBBR32(cp + pos + 24);
		uint16_t nameLen = JBBR16(cp + pos + 28);
		uint16_t extraLen = JBBR16(cp + pos + 30);
		uint16_t commentLen = JBBR16(cp + pos + 32);
		uint32_t localOffset = JBBR32(cp + pos + 42);
		pos += 46;
		if (pos + nameLen > cdSize) { fatal = YES; break; }

		NSString *name = [[NSString alloc] initWithBytes:cp + pos length:nameLen
												encoding:NSUTF8StringEncoding];
		if (!name.length) {
			name = [[NSString alloc] initWithBytes:cp + pos length:nameLen
										  encoding:NSISOLatin1StringEncoding];
		}
		pos += nameLen + extraLen + commentLen;

		BOOL isDirEntry = [name hasSuffix:@"/"];

		// ⚠️ Zip Slip 防护：可疑条目名一律拒（宁可少还原，不可写到目录外）
		NSString *dest = JBBSafeJoin(dir, name);
		if (!dest.length) {
			JBBLog(@"拒绝可疑条目名：%@", name);
			skipped++;
			continue;
		}

		if (isDirEntry) {
			JBBEnsureDir(dest);
			continue;
		}
		if (!JBBEnsureParentOf(dest)) { skipped++; continue; }

		// 跳到 local header，掠过它自己的 name/extra，定位到数据
		if (fseek(f, (long)localOffset, SEEK_SET) != 0) { fatal = YES; break; }
		uint8_t lh[30];
		if (fread(lh, 1, 30, f) != 30) { fatal = YES; break; }
		uint16_t lNameLen = JBBR16(lh + 26);
		uint16_t lExtraLen = JBBR16(lh + 28);
		if (fseek(f, (long)(localOffset + 30 + lNameLen + lExtraLen), SEEK_SET) != 0) {
			fatal = YES;
			break;
		}

		FILE *fo = fopen([dest fileSystemRepresentation], "wb");
		if (!fo) { skipped++; continue; }

		uint32_t gotCrc = 0;
		uint64_t gotSize = 0;
		BOOL fileOK = YES;

		if (csize == 0 && usize == 0) {
			gotCrc = (uint32_t)crc32(0L, Z_NULL, 0);
		} else if (method == 0) {
			// store：原样拷贝
			uLong crcAcc = crc32(0L, Z_NULL, 0);
			unsigned char buf[65536];
			uint32_t left = csize;
			while (left > 0 && fileOK) {
				size_t want = left > sizeof(buf) ? sizeof(buf) : left;
				size_t got = fread(buf, 1, want, f);
				if (got != want) { fileOK = NO; break; }
				crcAcc = crc32(crcAcc, buf, (uInt)got);
				if (!JBBWriteAll(fo, buf, got)) { fileOK = NO; break; }
				left -= (uint32_t)got;
				gotSize += got;
			}
			gotCrc = (uint32_t)crcAcc;
		} else if (method == 8) {
			// deflate：分块喂给 inflate（crc/size 在块之间累加，不能每块重算）
			z_stream zs;
			memset(&zs, 0, sizeof(zs));
			if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) {
				fileOK = NO;
			} else {
				uLong crcAcc = crc32(0L, Z_NULL, 0);
				uint64_t sizeAcc = 0;
				int ended = 0;
				unsigned char inBuf[65536];
				uint32_t left = csize;
				while (left > 0 && fileOK && ended != 2) {
					size_t want = left > sizeof(inBuf) ? sizeof(inBuf) : left;
					size_t got = fread(inBuf, 1, want, f);
					if (got != want) { fileOK = NO; break; }
					left -= (uint32_t)got;
					zs.next_in = inBuf;
					zs.avail_in = (uInt)got;
					while (zs.avail_in > 0 && fileOK && ended != 2) {
						int r = JBBInflatePump(&zs, fo, &crcAcc, &sizeAcc);
						if (r == 0) fileOK = NO;
						else if (r == 2) ended = 2;
					}
				}
				if (fileOK && ended != 2) {          // 收尾
					zs.next_in = (Bytef *)"";
					zs.avail_in = 0;
					if (JBBInflatePump(&zs, fo, &crcAcc, &sizeAcc) == 0) fileOK = NO;
				}
				inflateEnd(&zs);
				gotCrc = (uint32_t)crcAcc;
				gotSize = sizeAcc;
			}
		} else {
			fileOK = NO;                     // 用了我们不认识的方法（bzip2/lzma…）
		}

		fclose(fo);

		if (!fileOK) {
			JBBLog(@"条目解压失败：%@", name);
			[[NSFileManager defaultManager] removeItemAtPath:dest error:NULL];
			skipped++;
			continue;
		}
		if (usize && gotSize != usize) {
			JBBLog(@"条目大小对不上（期望 %u 实得 %llu）：%@", usize, gotSize, name);
		}
		if (crc && gotCrc != crc) {
			JBBLog(@"⚠️ CRC 校验不过（归档可能损坏）：%@", name);
		}

		files++;
	}

	fclose(f);

	// 单独再扫一遍中央目录补权限位（上面循环里位置计算容易错，拆出来更稳）
	{
		NSUInteger p2 = 0;
		for (uint16_t i = 0; i < count && p2 + 46 <= cdSize; i++) {
			if (!(cp[p2] == 0x50 && cp[p2 + 1] == 0x4b && cp[p2 + 2] == 0x01 && cp[p2 + 3] == 0x02)) break;
			uint16_t nameLen = JBBR16(cp + p2 + 28);
			uint16_t extraLen = JBBR16(cp + p2 + 30);
			uint16_t commentLen = JBBR16(cp + p2 + 32);
			uint32_t eattr = JBBR32(cp + p2 + 38);
			uint16_t mode = (uint16_t)((eattr >> 16) & 0xFFFF);
			NSString *name = [[NSString alloc] initWithBytes:cp + p2 + 46 length:nameLen
													encoding:NSUTF8StringEncoding];
			p2 += 46 + nameLen + extraLen + commentLen;
			if (mode == 0 || !name.length) continue;
			NSString *dest = JBBSafeJoin(dir, name);
			if (!dest.length) continue;
			chmod([dest fileSystemRepresentation], mode & 07777);
		}
	}

	if (fatal) {
		JBBNeed(err, @"ZIP 结构损坏，解析中途失败");
		JBBLog(@"解包中止：结构损坏，已解出 %lu 个文件", (unsigned long)files);
	}
	JBBLog(@"解包完成：%lu 个文件，跳过 %lu 个（%s）", (unsigned long)files, (unsigned long)skipped,
		   fatal ? "有错误" : "正常");
	return files;
}

#pragma mark - 解包（tar.gz，兼容 v0.1.0 的旧备份）

static unsigned long long JBBTarOctal(const char *p, size_t n) {
	unsigned long long v = 0;
	size_t i = 0;
	while (i < n && (p[i] == ' ' || p[i] == '0')) i++;
	for (; i < n; i++) {
		if (p[i] < '0' || p[i] > '7') break;
		v = v * 8 + (unsigned long long)(p[i] - '0');
	}
	return v;
}

+ (NSUInteger)extractTarGzAtPath:(NSString *)gzPath
					 toDirectory:(NSString *)dir
						   error:(NSString **)err {
	if (!gzPath.length || !dir.length) { JBBNeed(err, @"参数为空"); return 0; }
	if (!JBBEnsureDir(dir)) { JBBNeed(err, @"目标目录建不出来"); return 0; }

	gzFile gz = gzopen([gzPath fileSystemRepresentation], "rb");
	if (!gz) { JBBNeed(err, [NSString stringWithFormat:@"打不开文件：%@", gzPath]); return 0; }

	unsigned char hdr[512];
	NSUInteger files = 0, skipped = 0;
	NSString *pendingLongName = nil;
	BOOL fatal = NO;

	for (;;) {
		int got = gzread(gz, hdr, 512);
		if (got != 512) break;                          // 结束或截断
		BOOL allZero = YES;
		for (int i = 0; i < 512; i++) { if (hdr[i] != 0) { allZero = NO; break; } }
		if (allZero) break;                             // 结束块

		char nameBuf[101];
		memcpy(nameBuf, hdr, 100);
		nameBuf[100] = 0;
		NSString *name = [NSString stringWithUTF8String:nameBuf] ?: @"";
		char prefixBuf[156];
		memcpy(prefixBuf, hdr + 345, 155);
		prefixBuf[155] = 0;
		NSString *prefix = [NSString stringWithUTF8String:prefixBuf] ?: @"";
		if (prefix.length) name = [prefix stringByAppendingFormat:@"/%@", name];

		unsigned long long size = JBBTarOctal((const char *)hdr + 124, 12);
		char type = (char)hdr[156];

		// GNU long name：真实文件名在上一段数据里
		if (pendingLongName.length) {
			name = pendingLongName;
			pendingLongName = nil;
		}
		if (type == 'L') {
			NSMutableData *nb = [NSMutableData dataWithLength:(NSUInteger)size];
			if (size && gzread(gz, nb.mutableBytes, (unsigned int)size) != (int)size) break;
			pendingLongName = [[NSString alloc] initWithData:nb encoding:NSUTF8StringEncoding];
			pendingLongName = [pendingLongName stringByTrimmingCharactersInSet:
							   [NSCharacterSet newlineCharacterSet]];
			unsigned long long pad = (512 - (size % 512)) % 512;
			if (pad) { unsigned char skip[512]; gzread(gz, skip, (unsigned int)pad); }
			continue;
		}

		BOOL isDir = (type == '5') || [name hasSuffix:@"/"];
		BOOL isReg = (type == '0' || type == 0);

		NSString *dest = JBBSafeJoin(dir, name);
		if (!dest.length) {
			// 可疑条目：仍然要把数据跳过去，否则后面全乱
			unsigned long long pad = (512 - (size % 512)) % 512;
			unsigned long long skipTotal = size + pad;
			unsigned char skip[8192];
			while (skipTotal > 0) {
				unsigned int want = skipTotal > sizeof(skip) ? (unsigned int)sizeof(skip) : (unsigned int)skipTotal;
				int g = gzread(gz, skip, want);
				if (g <= 0) { fatal = YES; break; }
				skipTotal -= (unsigned long long)g;
			}
			JBBLog(@"拒绝可疑条目名：%@", name);
			skipped++;
			if (fatal) break;
			continue;
		}

		if (isDir) {
			JBBEnsureDir(dest);
			continue;
		}
		if (!isReg) {
			// 符号链接 / 硬链接 / 设备节点：不还原（备份里本来就没有，出现即异常）
			unsigned long long pad = (512 - (size % 512)) % 512;
			unsigned long long skipTotal = size + pad;
			unsigned char skip[8192];
			while (skipTotal > 0) {
				unsigned int want = skipTotal > sizeof(skip) ? (unsigned int)sizeof(skip) : (unsigned int)skipTotal;
				int g = gzread(gz, skip, want);
				if (g <= 0) { fatal = YES; break; }
				skipTotal -= (unsigned long long)g;
			}
			skipped++;
			if (fatal) break;
			continue;
		}

		if (!JBBEnsureParentOf(dest)) { skipped++; }
		FILE *fo = fopen([dest fileSystemRepresentation], "wb");
		unsigned long long left = size;
		unsigned char buf[65536];
		BOOL wOK = (fo != NULL);
		while (left > 0 && wOK) {
			unsigned int want = left > sizeof(buf) ? (unsigned int)sizeof(buf) : (unsigned int)left;
			int g = gzread(gz, buf, want);
			if (g <= 0) { wOK = NO; break; }
			if (!JBBWriteAll(fo, buf, (size_t)g)) { wOK = NO; break; }
			left -= (unsigned long long)g;
		}
		if (fo) fclose(fo);
		if (!wOK) {
			JBBLog(@"写文件失败：%@", dest);
			[[NSFileManager defaultManager] removeItemAtPath:dest error:NULL];
			skipped++;
		} else {
			files++;
		}
		unsigned long long pad = (512 - (size % 512)) % 512;
		unsigned char tail[512];
		if (pad) {
			if (gzread(gz, tail, (unsigned int)pad) != (int)pad) break;
		}
	}

	gzclose(gz);
	if (fatal) {
		JBBNeed(err, @"tar.gz 结构损坏");
	}
	JBBLog(@"tar.gz 解包：%lu 个文件，跳过 %lu 个", (unsigned long)files, (unsigned long)skipped);
	return files;
}

#pragma mark - 分派

+ (BOOL)isSupportedArchive:(NSString *)path {
	NSString *lower = [path lowercaseString];
	return [lower hasSuffix:@".zip"] || [lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"];
}

+ (NSUInteger)extractArchiveAtPath:(NSString *)archivePath
					   toDirectory:(NSString *)dir
							 error:(NSString **)err {
	NSString *lower = [archivePath lowercaseString];
	if ([lower hasSuffix:@".zip"]) {
		return [self extractZipAtPath:archivePath toDirectory:dir error:err];
	}
	if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tgz"]) {
		return [self extractTarGzAtPath:archivePath toDirectory:dir error:err];
	}
	JBBNeed(err, @"只支持 .zip / .tar.gz 备份文件");
	return 0;
}

@end
