//
//  tests/ziptest.m
//  JBBZip 往返自测 —— 只在 macOS 上跑（CI 用），不进 iOS 产物。
//
//  为什么值得单独写一个测试：
//    JBBZip 是本工程里唯一一块「手写的二进制格式编解码」—— 全部是
//    local header / central directory / EOCD / deflate 的字节级拼装。
//    它出错的后果特别贵：用户是「先备份 → 抹掉越狱 → 重新越狱 → 还原」，
//    等发现备份打不开时，原环境已经没了。所以必须在下发之前测穿。
//
//  为什么不能只做自洽测试：
//    「用我们写的 zip 喂给我们自己的解包器」是必然通过的 —— 哪怕两个方向
//    犯了完全对称的错误（比如 CRC 两边都错成同一个样子）。所以这里一律拿
//    **系统实现**做交叉验证：
//      · 我们写的 zip          → unzip -t 校验 CRC/结构（系统替我们验）
//      · 我们写的 zip          → ditto 解开后逐字节比对
//      · 系统 ditto 写的 zip   → 我们解开比对（用户在「文件」里重新压缩的情形）
//      · 系统 tar 写的 tar.gz  → 我们解开比对（v0.1.0 旧备份兼容）
//      · 恶意条目名（Zip Slip）→ 必须被拒，且不能落到目标目录之外
//
//  覆盖的几个「必须踩到」的边界：
//    · 0 字节文件
//    · 恰好 65536 / 65537 字节 —— 正是 inflate 的分块边界。历史上
//      「CRC 跨块没累加」那个 bug 就藏在这里：小文件全正常、大文件全错。
//    · 1.5MB 高熵数据（多块 + deflate 多轮输出）
//    · 中文名 / 空格名 / 深层嵌套
//    · 空目录（不写目录条目就会丢）
//    · 0600 权限位（还原 prefs 时权限错 = 插件读不到自己的配置）
//
//  有意不测的：符号链接。打包侧会把链接按「目标内容」存成普通文件，而
//    tar/ditto 会保留成链接条目 —— 两个语义都对，但横向比对必然产生伪差异。
//    本 App 的备份源（dpkg 数据库 + Library/Preferences）实际不含链接，
//    测它只会引入噪音，所以这里不造链接。
//

#import <Foundation/Foundation.h>
#import "JBBZip.h"
#import "JBBCommon.h"

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int gPass = 0;
static int gFail = 0;

static void ok(BOOL cond, NSString *what) {
	if (cond) {
		gPass++;
		printf("   [ok]   %s\n", what.UTF8String);
	} else {
		gFail++;
		printf("   [FAIL] %s\n", what.UTF8String);
	}
	fflush(stdout);
}

static void info(NSString *what) {
	printf("          %s\n", what.UTF8String);
	fflush(stdout);
}

static void section(NSString *title) {
	printf("\n=== %s ===\n", title.UTF8String);
	fflush(stdout);
}

#pragma mark - 外部命令

/// 跑一个外部命令，合并捕获 stdout+stderr，返回退出码（启动失败返回 -1）
static int sh(NSString *tool, NSArray<NSString *> *args, NSString **outText) {
	NSTask *t = [[NSTask alloc] init];
	t.launchPath = tool;
	t.arguments = args;
	NSPipe *p = [NSPipe pipe];
	t.standardOutput = p;
	t.standardError = p;
	@try {
		[t launch];
	} @catch (NSException *e) {
		if (outText) *outText = [NSString stringWithFormat:@"启动失败：%@", e.reason];
		return -1;
	}
	NSData *d = [p.fileHandleForReading readDataToEndOfFile];
	[t waitUntilExit];
	if (outText) *outText = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
	return t.terminationStatus;
}

static BOOL haveTool(NSString *path) {
	return [[NSFileManager defaultManager] isExecutableFileAtPath:path];
}

/// 找一个可用的 python3（runner 上 python3 的位置不固定，最后兜底走 PATH）
static NSArray<NSString *> *pythonCmd(void) {
	for (NSString *c in @[
			@"/usr/bin/python3",
			@"/usr/local/bin/python3",
			@"/opt/homebrew/bin/python3",
			@"/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]) {
		if (haveTool(c)) return @[c];
	}
	return @[@"/usr/bin/env", @"python3"];
}

#pragma mark - 目录树比对

/// 递归比对两棵目录树：条目集合 + 类型 + 每个文件的**内容字节**。
/// @return 差异描述数组（空 = 完全一致）
static NSArray<NSString *> *diffTrees(NSString *a, NSString *b) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray<NSString *> *bad = [NSMutableArray array];

	NSMutableSet<NSString *> *setA = [NSMutableSet set];
	NSMutableSet<NSString *> *setB = [NSMutableSet set];
	for (NSString *r in [fm enumeratorAtPath:a]) [setA addObject:r];
	for (NSString *r in [fm enumeratorAtPath:b]) [setB addObject:r];

	if (![setA isEqualToSet:setB]) {
		NSMutableSet *missing = [setA mutableCopy];
		[missing minusSet:setB];
		NSMutableSet *extra = [setB mutableCopy];
		[extra minusSet:setA];
		[bad addObject:[NSString stringWithFormat:@"条目集合不同 —— 缺 [%@] 多 [%@]",
						[[missing.allObjects sortedArrayUsingSelector:@selector(compare:)]
							componentsJoinedByString:@", "],
						[[extra.allObjects sortedArrayUsingSelector:@selector(compare:)]
							componentsJoinedByString:@", "]]];
	}

	for (NSString *rel in setA) {
		NSString *pa = [a stringByAppendingPathComponent:rel];
		NSString *pb = [b stringByAppendingPathComponent:rel];
		if (![fm fileExistsAtPath:pb]) continue;      // 已在「缺」里报过
		BOOL da = NO, db = NO;
		[fm fileExistsAtPath:pa isDirectory:&da];
		[fm fileExistsAtPath:pb isDirectory:&db];
		if (da != db) {
			[bad addObject:[NSString stringWithFormat:@"类型不同（目录/文件）：%@", rel]];
			continue;
		}
		if (da) continue;
		NSData *xa = [NSData dataWithContentsOfFile:pa];
		NSData *xb = [NSData dataWithContentsOfFile:pb];
		if (!xa || !xb) {
			[bad addObject:[NSString stringWithFormat:@"读不出来：%@", rel]];
		} else if (![xa isEqualToData:xb]) {
			[bad addObject:[NSString stringWithFormat:@"内容不同：%@（%lu 字节 vs %lu 字节）",
							rel, (unsigned long)xa.length, (unsigned long)xb.length]];
		}
	}
	return bad;
}

static void reportTreeDiff(NSString *label, NSArray<NSString *> *bad) {
	if (!bad.count) {
		ok(YES, [NSString stringWithFormat:@"%@：完全一致", label]);
		return;
	}
	ok(NO, [NSString stringWithFormat:@"%@：%lu 处差异", label, (unsigned long)bad.count]);
	for (NSString *d in bad) info([@"· " stringByAppendingString:d]);
}

#pragma mark - 造测试树

/// 高熵数据：能真正把 deflate 的多轮输出压出来（全零数据会被压成一片，测不到）
static BOOL writeFileOfSize(NSString *path, unsigned long long size, unsigned seed) {
	NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)size];
	uint8_t *p = d.mutableBytes;
	uint32_t x = seed ? seed : 1;
	for (unsigned long long i = 0; i < size; i++) {
		x = x * 1103515245u + 12345u;
		p[i] = (uint8_t)(x >> 16);
	}
	return [d writeToFile:path atomically:YES];
}

static BOOL buildTree(NSString *root) {
	NSFileManager *fm = [NSFileManager defaultManager];
	if (![fm createDirectoryAtPath:root withIntermediateDirectories:YES
						attributes:nil error:NULL]) return NO;

	JBBWriteText(@"hello jbbackup\n", [root stringByAppendingPathComponent:@"readme.txt"]);

	// 0 字节文件
	(void)[[NSData data] writeToFile:[root stringByAppendingPathComponent:@"empty.bin"] atomically:YES];

	// 分块边界：65536 / 65537 —— 「CRC 跨块没累加」的 bug 就死在这里
	if (!writeFileOfSize([root stringByAppendingPathComponent:@"exact64k.bin"], 65536, 7)) return NO;
	if (!writeFileOfSize([root stringByAppendingPathComponent:@"over64k.bin"], 65537, 11)) return NO;

	// 1.5MB 多块
	if (!writeFileOfSize([root stringByAppendingPathComponent:@"big1m5.bin"], 1536 * 1024, 23)) return NO;

	// 空目录（不写目录条目就会丢）
	NSString *emptyDir = [root stringByAppendingPathComponent:@"prefs/empty.d"];
	if (![fm createDirectoryAtPath:emptyDir withIntermediateDirectories:YES
						attributes:nil error:NULL]) return NO;

	// 中文名 + 空格名 + 深层嵌套
	NSString *deep = [root stringByAppendingPathComponent:@"Library/Preferences 带空格/更深/再深"];
	if (![fm createDirectoryAtPath:deep withIntermediateDirectories:YES
						attributes:nil error:NULL]) return NO;
	JBBWriteText(@"{ \"a\": 1 }\n", [deep stringByAppendingPathComponent:@"某插件 配置.plist"]);

	// 0600 权限位（还原 prefs 时权限错 = 插件读不到配置）
	NSString *secret = [root stringByAppendingPathComponent:@"prefs/secret.plist"];
	JBBWriteText(@"secret\n", secret);
	[fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:secret error:NULL];

	return YES;
}

/// 数一下目录下有几个「非目录」条目
static NSUInteger countFiles(NSString *root) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSUInteger n = 0;
	for (NSString *r in [fm enumeratorAtPath:root]) {
		BOOL d = NO;
		[fm fileExistsAtPath:[root stringByAppendingPathComponent:r] isDirectory:&d];
		if (!d) n++;
	}
	return n;
}

#pragma mark - main

int main(void) {
	@autoreleasepool {
		NSString *tmp = [NSString stringWithFormat:@"/tmp/jbb-ziptest-%d", (int)getpid()];
		NSFileManager *fm = [NSFileManager defaultManager];
		[fm removeItemAtPath:tmp error:NULL];
		if (![fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:NULL]) {
			printf("!! 建不出临时目录 %s\n", tmp.UTF8String);
			return 2;
		}

		NSString *src = [tmp stringByAppendingPathComponent:@"Backup_2026-01-01"];
		NSString *srcName = src.lastPathComponent;

		// ---------------------------------------------------------------
		section(@"0. 造测试树");
		BOOL built = buildTree(src);
		ok(built, @"测试树已生成");
		if (!built) { printf("!! 测试树没造出来，后面的比对没有意义\n"); return 2; }
		NSUInteger srcFiles = countFiles(src);
		info([NSString stringWithFormat:@"源树：%lu 个文件 / %llu 字节",
			  (unsigned long)srcFiles, JBBPathSize(src)]);

		// ---------------------------------------------------------------
		section(@"1. 我们打包 → 系统 unzip -t 验 CRC/结构（交叉验证，不是自洽）");
		NSString *ours = [tmp stringByAppendingPathComponent:@"ours.zip"];
		NSString *err = nil;
		unsigned long long zipBytes = [JBBZip createZipAtPath:ours fromDirectory:src error:&err];
		ok(zipBytes > 0, [NSString stringWithFormat:@"createZipAtPath 写出 %llu 字节%@",
						  zipBytes, err ? [@"（err: " stringByAppendingString:err] : @""]);
		if (zipBytes == 0) { printf("\n!! 打包就失败了，后面无需继续\n"); return 1; }

		if (haveTool(@"/usr/bin/unzip")) {
			NSString *out = nil;
			int rc = sh(@"/usr/bin/unzip", @[@"-t", ours], &out);
			ok(rc == 0, [NSString stringWithFormat:@"unzip -t 退出码 %d（CRC 由系统实现来验）", rc]);
			if (rc != 0) {
				for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
					BOOL bad = [line rangeOfString:@"error" options:NSCaseInsensitiveSearch].location != NSNotFound
							|| [line rangeOfString:@"bad" options:NSCaseInsensitiveSearch].location != NSNotFound
							|| [line rangeOfString:@"CRC" options:NSCaseInsensitiveSearch].location != NSNotFound;
					if (bad) info([@"· " stringByAppendingString:line]);
				}
			}
		} else {
			ok(NO, @"找不到 /usr/bin/unzip —— 无法交叉验证，CI 环境异常");
		}

		// ---------------------------------------------------------------
		section(@"2. 我们打包 → 系统 ditto 解开 → 逐字节比对");
		if (haveTool(@"/usr/bin/ditto")) {
			NSString *sysOut = [tmp stringByAppendingPathComponent:@"by-system"];
			[fm createDirectoryAtPath:sysOut withIntermediateDirectories:YES attributes:nil error:NULL];
			int rc = sh(@"/usr/bin/ditto", @[@"-x", @"-k", ours, sysOut], NULL);
			ok(rc == 0, [NSString stringWithFormat:@"ditto 解开退出码 %d", rc]);
			if (rc == 0) {
				reportTreeDiff(@"系统解开的结果 vs 源树",
							   diffTrees(src, [sysOut stringByAppendingPathComponent:srcName]));
			}
		} else {
			ok(NO, @"找不到 /usr/bin/ditto");
		}

		// ---------------------------------------------------------------
		section(@"3. 我们打包 → 我们解开 → 逐字节比对 + 权限位");
		NSString *ourOut = [tmp stringByAppendingPathComponent:@"by-ours"];
		err = nil;
		NSUInteger n = [JBBZip extractZipAtPath:ours toDirectory:ourOut error:&err];
		ok(n == srcFiles, [NSString stringWithFormat:@"解出 %lu 个文件（源树 %lu 个）%@",
						   (unsigned long)n, (unsigned long)srcFiles,
						   err ? [@"（err: " stringByAppendingString:err] : @""]);
		reportTreeDiff(@"我们解开的结果 vs 源树",
					   diffTrees(src, [ourOut stringByAppendingPathComponent:srcName]));

		NSString *restoredSecret = [ourOut stringByAppendingPathComponent:
			[srcName stringByAppendingPathComponent:@"prefs/secret.plist"]];
		if ([fm fileExistsAtPath:restoredSecret]) {
			NSDictionary *at = [fm attributesOfItemAtPath:restoredSecret error:NULL];
			unsigned int mode = (unsigned int)([at[NSFilePosixPermissions] unsignedShortValue] & 07777);
			ok(mode == 0600, [NSString stringWithFormat:@"prefs/secret.plist 权限位还原为 0%o（应为 0600）", mode]);
		} else {
			ok(NO, @"prefs/secret.plist 没解出来");
		}

		NSString *emptyRestored = [ourOut stringByAppendingPathComponent:
			[srcName stringByAppendingPathComponent:@"prefs/empty.d"]];
		BOOL isDir = NO;
		ok([fm fileExistsAtPath:emptyRestored isDirectory:&isDir] && isDir,
		   @"空目录 prefs/empty.d 被还原（说明目录条目确实写进去了）");

		// ---------------------------------------------------------------
		section(@"4. 系统 ditto 打包 → 我们解开（用户在「文件」里重新压缩的情形）");
		if (haveTool(@"/usr/bin/ditto")) {
			NSString *sysZip = [tmp stringByAppendingPathComponent:@"by-system.zip"];
			int rc = sh(@"/usr/bin/ditto",
						@[@"-c", @"-k", @"--norsrc", @"--keepParent", src, sysZip], NULL);
			ok(rc == 0, [NSString stringWithFormat:@"ditto 打包退出码 %d", rc]);
			if (rc == 0) {
				NSString *o2 = [tmp stringByAppendingPathComponent:@"from-system"];
				err = nil;
				NSUInteger n2 = [JBBZip extractZipAtPath:sysZip toDirectory:o2 error:&err];
				ok(n2 == srcFiles, [NSString stringWithFormat:@"解开系统 zip：%lu 个文件（源树 %lu）%@",
							(unsigned long)n2, (unsigned long)srcFiles,
							err ? [@"（err: " stringByAppendingString:err] : @""]);
				reportTreeDiff(@"解系统 zip 的结果 vs 源树",
							   diffTrees(src, [o2 stringByAppendingPathComponent:srcName]));
				if (n2 != srcFiles) {
					info(@"计数不符，列出解出条目供核对：");
					for (NSString *r in [fm enumeratorAtPath:o2]) info([@"· " stringByAppendingString:r]);
				}
			}
		} else {
			ok(NO, @"找不到 /usr/bin/ditto");
		}

		// ---------------------------------------------------------------
		section(@"5. 系统 tar czf 打包 → 我们解开（v0.1.0 旧备份兼容）");
		if (haveTool(@"/usr/bin/tar")) {
			NSString *sysTgz = [tmp stringByAppendingPathComponent:@"by-system.tar.gz"];
			int rc = sh(@"/usr/bin/tar", @[@"-czf", sysTgz, @"-C", tmp, srcName], NULL);
			ok(rc == 0, [NSString stringWithFormat:@"tar czf 退出码 %d", rc]);
			if (rc == 0) {
				NSString *o3 = [tmp stringByAppendingPathComponent:@"from-targz"];
				err = nil;
				NSUInteger n3 = [JBBZip extractTarGzAtPath:sysTgz toDirectory:o3 error:&err];

				// ⚠️ 刻意**不**断言「解包器自报计数 == 源树文件数」：
				//    macOS 的 bsdtar 会额外写 pax 元数据条目（携带扩展属性），
				//    解包器会把它们跳过 —— 实测自报 10、其中 7 个是跳过的 pax 头。
				//    那既不是内容错位也不是 bug，拿它当断言只会让人误以为有问题。
				//    真正有意义的不变量是下面两条：**落盘文件数**正确 + **逐字节一致**。
				NSUInteger landed = countFiles([o3 stringByAppendingPathComponent:srcName]);
				ok(landed == srcFiles, [NSString stringWithFormat:
							@"tar.gz 落盘文件数 = %lu（源树 %lu）",
							(unsigned long)landed, (unsigned long)srcFiles]);
				if (n3 != landed) {
					info([NSString stringWithFormat:
						  @"解包器自报处理了 %lu 个常规条目，落盘 %lu 个 —— 差额是工具附加的元数据条目",
						  (unsigned long)n3, (unsigned long)landed]);
				}
				reportTreeDiff(@"解 tar.gz 的结果 vs 源树",
							   diffTrees(src, [o3 stringByAppendingPathComponent:srcName]));
				if (landed != srcFiles) {
					info(@"落盘文件数不符，列出条目供核对：");
					for (NSString *r in [fm enumeratorAtPath:o3]) info([@"· " stringByAppendingString:r]);
				}
			}
		} else {
			ok(NO, @"找不到 /usr/bin/tar");
		}

		// ---------------------------------------------------------------
		section(@"6. Zip Slip：恶意条目名必须被拒，且不能落到目标目录之外");
		{
			// 用 python3 的 zipfile 造两个「只有手工才造得出来」的恶意包
			NSString *py = @
				"import sys, zipfile\n"
				"kind, out = sys.argv[1], sys.argv[2]\n"
				"z = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)\n"
				"if kind == 'rel':\n"
				"    z.writestr('../escaped-relative.txt', 'PWNED-rel')\n"
				"else:\n"
				"    z.writestr('/tmp/jbb-escaped-absolute.txt', 'PWNED-abs')\n"
				"z.writestr('ok/inside.txt', 'fine')\n"
				"z.close()\n";

			NSArray<NSString *> *pyCmd = pythonCmd();
			info([NSString stringWithFormat:@"python3 用：%@",
				  [pyCmd componentsJoinedByString:@" "]]);

			NSArray<NSString *> *kinds = @[@"rel", @"abs"];
			NSArray<NSString *> *outs = @[
				[tmp stringByAppendingPathComponent:@"evil-rel.zip"],
				[tmp stringByAppendingPathComponent:@"evil-abs.zip"],
			];
			NSArray<NSString *> *canaries = @[
				[tmp stringByAppendingPathComponent:@"escaped-relative.txt"],
				@"/tmp/jbb-escaped-absolute.txt",
			];

			for (NSUInteger i = 0; i < kinds.count; i++) {
				[fm removeItemAtPath:canaries[i] error:NULL];

				NSMutableArray<NSString *> *args = [pyCmd mutableCopy];
				[args addObjectsFromArray:@[@"-c", py, kinds[i], outs[i]]];
				NSString *pyErr = nil;
				int rc = sh(args[0], [args subarrayWithRange:NSMakeRange(1, args.count - 1)], &pyErr);
				ok(rc == 0, [NSString stringWithFormat:@"造出恶意包（%@）rc=%d", kinds[i], rc]);
				if (rc != 0) { info(pyErr); continue; }

				NSString *dest = [tmp stringByAppendingPathComponent:
								  [@"slip-" stringByAppendingString:kinds[i]]];
				[fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:NULL];
				err = nil;
				[JBBZip extractZipAtPath:outs[i] toDirectory:dest error:&err];

				BOOL escaped = [fm fileExistsAtPath:canaries[i]];
				ok(!escaped, [NSString stringWithFormat:@"[%@] 越界文件没被写出（%s）",
							  kinds[i], canaries[i].UTF8String]);
				if (escaped) [fm removeItemAtPath:canaries[i] error:NULL];

				// 同包内正常的那个条目应该仍在（证明只是拒了可疑条目，没整包放弃）
				ok([fm fileExistsAtPath:[dest stringByAppendingPathComponent:@"ok/inside.txt"]],
				   [NSString stringWithFormat:@"[%@] 同包内正常条目仍被解出", kinds[i]]);
			}
		}

		// ---------------------------------------------------------------
		section(@"7. 杂项：后缀分派 / 非法输入不许崩");
		ok([JBBZip isSupportedArchive:@"a.zip"], @"识别 .zip");
		ok([JBBZip isSupportedArchive:@"a.tar.gz"], @"识别 .tar.gz");
		ok([JBBZip isSupportedArchive:@"a.tgz"], @"识别 .tgz");
		ok([JBBZip isSupportedArchive:@"a.TAR.GZ"], @"识别大写 .TAR.GZ");
		ok(![JBBZip isSupportedArchive:@"a.rar"], @"不认 .rar");

		NSString *junk = [tmp stringByAppendingPathComponent:@"junk.zip"];
		JBBWriteText(@"this is definitely not a zip file", junk);
		NSString *jd = [tmp stringByAppendingPathComponent:@"junk-out"];
		err = nil;
		NSUInteger jn = [JBBZip extractZipAtPath:junk toDirectory:jd error:&err];
		ok(jn == 0 && err.length > 0, @"喂垃圾文件：返回 0 且给出错误文案（不崩）");

		err = nil;
		unsigned long long z0 = [JBBZip createZipAtPath:[tmp stringByAppendingPathComponent:@"nope.zip"]
										  fromDirectory:[tmp stringByAppendingPathComponent:@"不存在"]
												  error:&err];
		ok(z0 == 0 && err.length > 0, @"打不存在的目录：返回 0 且给出错误文案（不崩）");

		err = nil;
		NSUInteger an = [JBBZip extractArchiveAtPath:@"whatever.rar" toDirectory:tmp error:&err];
		ok(an == 0 && err.length > 0, @"不支持的归档后缀：明确报错");

		err = nil;
		NSUInteger en = [JBBZip extractZipAtPath:@"" toDirectory:tmp error:&err];
		ok(en == 0 && err.length > 0, @"空路径：明确报错（不崩）");

		// ---------------------------------------------------------------
		printf("\n---------------------------------------------\n");
		printf("  通过 %d   失败 %d\n", gPass, gFail);
		printf("---------------------------------------------\n");
		if (gFail == 0) printf("  ✅ JBBZip 往返自测全部通过\n\n");
		else            printf("  ❌ 有 %d 项失败，见上面的 [FAIL]\n\n", gFail);
		fflush(stdout);

		[fm removeItemAtPath:tmp error:NULL];
		return gFail == 0 ? 0 : 1;
	}
}
