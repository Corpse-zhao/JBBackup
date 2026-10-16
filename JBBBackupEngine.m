//
//  JBBBackupEngine.m
//

#import "JBBBackupEngine.h"
#import "JBBCommon.h"
#import "JBBZip.h"
#import <sys/utsname.h>
#import <time.h>

#pragma mark - 选项

@implementation JBBBackupOptions

+ (instancetype)defaultOptions {
	JBBBackupOptions *o = [[JBBBackupOptions alloc] init];
	o.includeApplePrefs    = NO;
	o.includeContainerPrefs = YES;
	o.includeAppSupport    = YES;
	o.includeAptCache      = YES;
	o.includeMedia         = NO;
	return o;
}

- (NSDictionary *)dictionaryRepresentation {
	return @{
		@"applePrefs":     @(self.includeApplePrefs),
		@"containerPrefs": @(self.includeContainerPrefs),
		@"appSupport":     @(self.includeAppSupport),
		@"aptCache":       @(self.includeAptCache),
		@"media":          @(self.includeMedia),
	};
}

+ (instancetype)optionsFromDictionary:(NSDictionary *)dict {
	JBBBackupOptions *o = [self defaultOptions];
	if (![dict isKindOfClass:[NSDictionary class]]) return o;
	id v = nil;
	if ((v = dict[@"applePrefs"]))     o.includeApplePrefs     = [v boolValue];
	if ((v = dict[@"containerPrefs"])) o.includeContainerPrefs = [v boolValue];
	if ((v = dict[@"appSupport"]))     o.includeAppSupport     = [v boolValue];
	if ((v = dict[@"aptCache"]))       o.includeAptCache       = [v boolValue];
	if ((v = dict[@"media"]))          o.includeMedia          = [v boolValue];
	return o;
}

@end

#pragma mark - 结果

@implementation JBBBackupResult
@end

#pragma mark - 工具

static NSString *JBBDeviceMachine(void) {
	struct utsname u;
	memset(&u, 0, sizeof(u));
	if (uname(&u) == 0) {
		NSString *s = [NSString stringWithUTF8String:u.machine];
		if (s.length) return s;
	}
	return @"unknown";
}

static NSString *JBBISOTime(void) {
	time_t t = time(NULL);
	struct tm tmv;
	memset(&tmv, 0, sizeof(tmv));
	localtime_r(&t, &tmv);
	char buf[32];
	strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tmv);
	return [NSString stringWithUTF8String:buf] ?: @"";
}

static NSString *JBBIOSVersion(void) {
	NSString *v = [[NSProcessInfo processInfo] operatingSystemVersionString] ?: @"";
	NSRange r = [v rangeOfString:@"Version "];
	if (r.location != NSNotFound) {
		v = [v substringFromIndex:r.location + r.length];
	}
	return v.length ? v : @"?";
}

static void JBBReport(JBBProgressBlock progress, NSString *stage, double fraction) {
	if (!progress) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		progress(stage, fraction);
	});
}

/// 复制单个文件（覆盖已存在的目标）。目标父目录会自动创建。
static BOOL JBBCopyFileSafe(NSString *src, NSString *dst, NSMutableArray<NSString *> *warns) {
	if (!src.length || !dst.length) return NO;
	NSFileManager *fm = [NSFileManager defaultManager];
	if (![fm fileExistsAtPath:src]) return NO;
	if (!JBBEnsureDir([dst stringByDeletingLastPathComponent])) {
		if (warns) [warns addObject:[NSString stringWithFormat:@"建目录失败：%@", [dst stringByDeletingLastPathComponent]]];
		return NO;
	}
	[fm removeItemAtPath:dst error:NULL];
	NSError *err = nil;
	if ([fm copyItemAtPath:src toPath:dst error:&err]) return YES;
	if (warns) [warns addObject:[NSString stringWithFormat:@"复制失败 %@ → %@（%@）",
								 [src lastPathComponent], dst, err.localizedDescription ?: @"未知"]];
	return NO;
}

/// 复制整个目录（带体积上限，超限则跳过并记录）
static BOOL JBBCopyDirSafe(NSString *src, NSString *dst, unsigned long long capBytes,
						   NSMutableArray<NSString *> *warns) {
	NSFileManager *fm = [NSFileManager defaultManager];
	if (![fm fileExistsAtPath:src]) return NO;
	unsigned long long size = JBBPathSize(src);
	if (capBytes > 0 && size > capBytes) {
		if (warns) [warns addObject:[NSString stringWithFormat:@"跳过（%@ > 上限 %@）：%@",
									 JBBHumanSize(size), JBBHumanSize(capBytes), [src lastPathComponent]]];
		return NO;
	}
	if (!JBBEnsureDir([dst stringByDeletingLastPathComponent])) return NO;
	[fm removeItemAtPath:dst error:NULL];
	NSError *err = nil;
	if ([fm copyItemAtPath:src toPath:dst error:&err]) return YES;
	if (warns) [warns addObject:[NSString stringWithFormat:@"复制目录失败 %@（%@）",
								 [src lastPathComponent], err.localizedDescription ?: @"未知"]];
	return NO;
}

#pragma mark - 引擎

@implementation JBBBackupEngine

+ (NSArray<NSString *> *)listBackupNames {
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (NSString *name in JBBListDir(JBBOutputRoot())) {
		if (!name.length || [name hasPrefix:@"_"] || [name hasPrefix:@"."]) continue;
		// 归档产物不进「备份列表」（可解压的备份文件不能当目录用）
		if ([name hasSuffix:@".zip"] || [name hasSuffix:@".tar.gz"] ||
			[name hasSuffix:@".tgz"]) continue;
		NSString *full = [JBBOutputRoot() stringByAppendingPathComponent:name];
		BOOL isDir = NO;
		if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir] || !isDir) continue;
		// 只认「看起来像备份」的目录：必须有 manifest 或 packages 子目录
		if (!JBBFileExists([full stringByAppendingPathComponent:@"manifest.plist"]) &&
			!JBBFileExists([full stringByAppendingPathComponent:@"packages"])) continue;
		[names addObject:name];
	}
	// 时间戳命名 → 字典序倒序即时间倒序
	return [names sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
		return [b compare:a];
	}];
}

+ (NSString *)pathForBackupName:(NSString *)name {
	if (!name.length) return nil;
	return [JBBOutputRoot() stringByAppendingPathComponent:name];
}

+ (NSString *)archiveBackupDirNamed:(NSString *)name {
	NSString *dir = [self pathForBackupName:name];
	if (!JBBFileExists(dir)) return nil;

	NSString *parent = [dir stringByDeletingLastPathComponent];
	NSString *base = [dir lastPathComponent];
	NSString *archive = [parent stringByAppendingPathComponent:
						 [base stringByAppendingPathExtension:@"zip"]];

	[[NSFileManager defaultManager] removeItemAtPath:archive error:NULL];

	// ⭐ 用自带的 ZIP 编码（JBBZip），不再 spawn 外部 tar 二进制。
	//    老做法的三个问题：
	//      ① 不同越狱环境 tar 的位置不一样，找不到就整个打包失败；
	//      ② 「从文件里选备份还原」这条路上根本没有可用的 tar 去解包；
	//      ③ 用户拿到 tar.gz 在「文件」App 里点开是打不开的，ZIP 才是通用格式。
	NSString *err = nil;
	unsigned long long n = [JBBZip createZipAtPath:archive fromDirectory:dir error:&err];
	if (n == 0 || !JBBFileExists(archive)) {
		JBBLog(@"打包失败：%@（备份目录本身完整可用）", err ?: @"未知原因");
		return nil;
	}
	JBBLog(@"打包完成：%@（%@）", archive, JBBHumanSize(n));
	return archive;
}

#pragma mark - 删除备份

/// 归档后缀白名单（只有这些扩展名才允许被当成「备份的归档」删掉）
static NSArray<NSString *> *JBBArchiveExts(void) {
	return @[@"zip", @"tar.gz", @"tgz"];
}

/// ⚠️ 防呆：只接受「一个直接位于备份根目录下的目录名」。
///    不加这个校验的话，`../../var/mobile/Library` 或者 `_appconfig.plist`
///    这样的名字一旦进来就会把备份根目录之外的东西端掉。
static BOOL JBBIsSafeBackupName(NSString *name) {
	if (!name.length) return NO;
	if ([name containsString:@"/"] || [name containsString:@"\\"]) return NO;
	if ([name rangeOfString:@":"].location != NSNotFound) return NO;
	if ([name hasPrefix:@"."] || [name hasPrefix:@"_"]) return NO;   // _appconfig.plist / _restore-safety-*
	if ([name isEqualToString:@".."] || [name isEqualToString:@"."]) return NO;
	return YES;
}

+ (NSArray<NSString *> *)locationsForBackupNamed:(NSString *)name {
	if (!JBBIsSafeBackupName(name)) return @[];
	NSMutableArray<NSString *> *out = [NSMutableArray array];
	// 两个根：本地 与 iCloud Drive
	NSArray<NSString *> *roots = @[JBBOutputRoot() ?: @"", JBBIcloudRoot() ?: @""];
	for (NSString *root in roots) {
		if (!root.length) continue;

		// 目录形态（备份的原始形态）
		NSString *dir = [root stringByAppendingPathComponent:name];
		if (JBBFileExists(dir)) [out addObject:dir];

		// 归档形态。⚠️ 两个根都要找：备份时如果 iCloud 复制失败会退化成
		// 「只写目录」，所以 iCloud 那边可能只有目录、也可能只有归档。
		for (NSString *ext in JBBArchiveExts()) {
			NSString *a = [root stringByAppendingPathComponent:
						   [name stringByAppendingPathExtension:ext]];
			if (JBBFileExists(a)) [out addObject:a];
		}
	}
	return out;
}

+ (unsigned long long)totalSizeForBackupNamed:(NSString *)name {
	unsigned long long total = 0;
	for (NSString *p in [self locationsForBackupNamed:name]) total += JBBPathSize(p);
	return total;
}

+ (unsigned long long)deleteBackupNamed:(NSString *)name error:(NSString **)errOut {
	if (errOut) *errOut = nil;

	if (!JBBIsSafeBackupName(name)) {
		if (errOut) *errOut = [NSString stringWithFormat:
							   @"拒绝删除：备份名不合法（%@）", name.length ? name : @"空"];
		JBBLog(@"⚠️ 拒绝删除，备份名不合法：%@", name ?: @"(nil)");
		return 0;
	}

	NSArray<NSString *> *locs = [self locationsForBackupNamed:name];
	if (!locs.count) {
		if (errOut) *errOut = [NSString stringWithFormat:
							   @"找不到备份「%@」（本地与 iCloud 都没有）", name];
		return 0;
	}

	// ⚠️ 双保险：目录必须「看起来像备份」才删。归档文件的后缀已由
	//    locationsForBackupNamed 限死（zip/tar.gz/tgz），不再额外判。
	NSMutableArray<NSString *> *victims = [NSMutableArray array];
	NSFileManager *fm = [NSFileManager defaultManager];
	for (NSString *p in locs) {
		BOOL isDir = NO;
		[fm fileExistsAtPath:p isDirectory:&isDir];
		if (!isDir) { [victims addObject:p]; continue; }
		BOOL looksLikeBackup =
			JBBFileExists([p stringByAppendingPathComponent:@"manifest.plist"]) ||
			JBBFileExists([p stringByAppendingPathComponent:@"packages"]);
		if (looksLikeBackup) {
			[victims addObject:p];
		} else {
			JBBLog(@"跳过「不像备份」的目录，不删：%@", p);
		}
	}
	if (!victims.count) {
		if (errOut) *errOut = @"找到的条目都不像是备份，已放弃删除";
		return 0;
	}

	// ⚠️ 体积必须在删之前算 —— 删完再算就是 0 了
	unsigned long long total = 0;
	for (NSString *p in victims) total += JBBPathSize(p);

	NSMutableArray<NSString *> *failed = [NSMutableArray array];
	for (NSString *p in victims) {
		NSError *e = nil;
		if ([fm removeItemAtPath:p error:&e]) {
			JBBLog(@"已删除：%@", p);
		} else {
			[failed addObject:[NSString stringWithFormat:@"%@（%@）",
							   p, e.localizedDescription ?: @"未知原因"]];
		}
	}

	if (failed.count) {
		if (errOut) *errOut = [NSString stringWithFormat:@"有 %lu 处没删掉：\n%@",
							   (unsigned long)failed.count,
							   [failed componentsJoinedByString:@"\n"]];
	}
	JBBLog(@"===== 删除备份「%@」：%lu 处 / 释放 %@%@ =====",
		   name, (unsigned long)(victims.count - failed.count), JBBHumanSize(total),
		   failed.count ? [NSString stringWithFormat:@"（%lu 处失败）", (unsigned long)failed.count] : @"");
	return total;
}

+ (JBBBackupResult *)backupWithOptions:(JBBBackupOptions *)options
							  progress:(JBBProgressBlock)progress {
	JBBBackupResult *res = [[JBBBackupResult alloc] init];
	NSMutableArray<NSString *> *warns = [NSMutableArray array];

	if (!options) options = [JBBBackupOptions defaultOptions];

	JBBReport(progress, @"检查越狱环境…", 0.02);
	NSString *jbroot = JBBJBRoot();
	if (!jbroot.length) {
		res.ok = NO;
		res.warnings = @"未探测到越狱环境（jbroot 里找不到 var/lib/dpkg/status），备份无法进行。";
		JBBLog(@"备份中止：%@", res.warnings);
		return res;
	}

	NSString *stamp = JBBTimestampString();
	NSString *outRoot = JBBOutputRoot();
	if (!JBBEnsureDir(outRoot)) {
		res.ok = NO;
		res.warnings = [NSString stringWithFormat:@"输出目录不可写：%@", outRoot];
		JBBLog(@"备份中止：%@", res.warnings);
		return res;
	}
	NSString *dir = [outRoot stringByAppendingPathComponent:stamp];
	if (!JBBEnsureDir(dir)) {
		res.ok = NO;
		res.warnings = [NSString stringWithFormat:@"创建备份目录失败：%@", dir];
		JBBLog(@"备份中止：%@", res.warnings);
		return res;
	}
	res.dirPath = dir;
	JBBLog(@"===== 开始备份 → %@ =====", dir);

	JBBEnsureDir([dir stringByAppendingPathComponent:@"packages"]);
	JBBEnsureDir([dir stringByAppendingPathComponent:@"prefs/global"]);
	JBBEnsureDir([dir stringByAppendingPathComponent:@"sources"]);

	// ---------- 1. 包列表 ----------
	JBBReport(progress, @"读取 dpkg 数据库…", 0.05);
	NSArray<NSDictionary *> *allPkgs = JBBInstalledPackages();
	NSArray<NSString *> *manualPkgs = JBBManualPackageNames();
	res.packageTotal = allPkgs.count;
	res.packageManual = manualPkgs.count;

	NSString *extStates = [jbroot stringByAppendingPathComponent:@"var/lib/apt/extended_states"];
	res.manualIsExact = JBBFileExists(extStates);
	NSString *manualSourceNote = res.manualIsExact
		? @"apt extended_states（Auto-Installed: 0，精确）"
		: @"兜底近似（未找到 extended_states，用「全部已安装 − 基础包名提示表」推算）";

	NSString *pkgHead = [NSString stringWithFormat:
		@"# JBBackup %@ 备份的包列表\n# 时间：%@\n# 设备：%@  iOS：%@\n# jbroot：%@\n"
		@"# 手动安装清单来源：%@\n# 格式：name|version|section|origin\n",
		JBB_VERSION, JBBISOTime(), JBBDeviceMachine(), JBBIOSVersion(), jbroot, manualSourceNote];

	NSMutableString *allTxt = [NSMutableString stringWithString:pkgHead];
	for (NSDictionary *p in allPkgs) {
		[allTxt appendFormat:@"%@|%@|%@|%@\n", p[@"name"], p[@"version"], p[@"section"], p[@"origin"]];
	}
	JBBWriteText(allTxt, [dir stringByAppendingPathComponent:@"packages/packages-all.txt"]);

	NSMutableString *manTxt = [NSMutableString stringWithString:pkgHead];
	NSMutableString *manPlain = [NSMutableString string];
	NSSet<NSString *> *manualSet = [NSSet setWithArray:manualPkgs];
	for (NSDictionary *p in allPkgs) {
		NSString *n = p[@"name"];
		if (![manualSet containsObject:n]) continue;
		[manTxt appendFormat:@"%@|%@|%@|%@\n", n, p[@"version"], p[@"section"], p[@"origin"]];
		[manPlain appendFormat:@"%@\n", n];
	}
	JBBWriteText(manTxt, [dir stringByAppendingPathComponent:@"packages/packages-manual.txt"]);
	JBBWriteText(manPlain, [dir stringByAppendingPathComponent:@"packages/packages-manual-plain.txt"]);
	JBBLog(@"包列表：共 %lu 个，手动安装 %lu 个（%@）",
		   (unsigned long)res.packageTotal, (unsigned long)res.packageManual,
		   res.manualIsExact ? @"精确" : @"近似");

	// ---------- 2. apt 源 ----------
	JBBReport(progress, @"备份 apt 源…", 0.10);
	NSString *sourcesDir = [dir stringByAppendingPathComponent:@"sources"];
	NSMutableArray<NSString *> *srcMap = [NSMutableArray arrayWithObject:@"# 备份内文件名\t原始路径"];
	int srcIdx = 0;
	for (NSString *src in JBBSourceFilePaths()) {
		NSString *base = [src lastPathComponent];
		NSString *dst = [sourcesDir stringByAppendingPathComponent:base];
		if (JBBFileExists(dst)) {
			dst = [sourcesDir stringByAppendingPathComponent:
				   [NSString stringWithFormat:@"%d-%@", srcIdx, base]];
		}
		if (JBBCopyFileSafe(src, dst, warns)) {
			res.sourceFiles++;
			[srcMap addObject:[NSString stringWithFormat:@"%@\t%@", [dst lastPathComponent], src]];
		}
		srcIdx++;
	}
	JBBWriteText([srcMap componentsJoinedByString:@"\n"],
				 [sourcesDir stringByAppendingPathComponent:@"_sources-map.tsv"]);
	JBBLog(@"apt 源：%lu 个文件", (unsigned long)res.sourceFiles);

	// ---------- 3. 全局插件配置 ----------
	JBBReport(progress, @"备份全局插件配置…", 0.15);
	NSString *prefSrc = @"/var/mobile/Library/Preferences";
	NSString *prefDst = [dir stringByAppendingPathComponent:@"prefs/global"];
	NSArray<NSString *> *prefNames = JBBListDir(prefSrc);
	NSUInteger skippedApple = 0;
	NSMutableArray<NSString *> *prefIndex = [NSMutableArray arrayWithObject:@"# 全局偏好文件（/var/mobile/Library/Preferences）"];
	NSUInteger prefDone = 0;
	for (NSString *name in prefNames) {
		if (![name hasSuffix:@".plist"]) continue;
		if ([name isEqualToString:@".GlobalPreferences.plist"]) continue;
		if (!options.includeApplePrefs && [name hasPrefix:@"com.apple."]) { skippedApple++; continue; }
		if (JBBCopyFileSafe([prefSrc stringByAppendingPathComponent:name],
							[prefDst stringByAppendingPathComponent:name], warns)) {
			res.prefsGlobal++;
			[prefIndex addObject:name];
		}
		prefDone++;
		if ((prefDone % 40) == 0) {
			JBBReport(progress, [NSString stringWithFormat:@"备份全局配置…（%lu）", (unsigned long)res.prefsGlobal], 0.15);
		}
	}
	[prefIndex addObject:[NSString stringWithFormat:@"# 已跳过 com.apple.* 系统偏好 %lu 个（如需一并备份，请在设置里打开开关）", (unsigned long)skippedApple]];
	JBBWriteText([prefIndex componentsJoinedByString:@"\n"],
				 [prefDst stringByAppendingPathComponent:@"_index.txt"]);
	JBBLog(@"全局配置：%lu 个（跳过 com.apple.* %lu 个）",
		   (unsigned long)res.prefsGlobal, (unsigned long)skippedApple);

	// ---------- 4. 各 App 沙盒内的插件配置 ----------
	if (options.includeContainerPrefs) {
		JBBReport(progress, @"扫描 App 沙盒…", 0.45);
		NSString *cDst = [dir stringByAppendingPathComponent:@"prefs/containers"];
		JBBEnsureDir(cDst);
		NSMutableArray<NSString *> *map = [NSMutableArray arrayWithObject:@"# bundleId\t容器UUID\t容器路径\t本次拷贝文件数"];
		NSMutableArray<NSString *> *libDirs = [NSMutableArray arrayWithObject:@"# 各容器 Library/ 下的子目录（未拷贝，仅清单：万一你的插件把配置放这里，把这一行发给作者即可加进来）"];
		NSArray<NSString *> *containers = JBBAppContainerPaths();
		NSUInteger scanned = 0;
		for (NSString *container in containers) {
			scanned++;
			NSString *bid = JBBContainerBundleID(container);
			if (!bid.length) continue;

			// 清单：这个容器的 Library 下有哪些子目录
			NSArray<NSString *> *libSub = JBBListDir([container stringByAppendingPathComponent:@"Library"]);
			if (libSub.count) {
				[libDirs addObject:[NSString stringWithFormat:@"%@\t%@", bid, [libSub componentsJoinedByString:@", "]]];
			}

			NSString *pdir = [container stringByAppendingPathComponent:@"Library/Preferences"];
			NSArray<NSString *> *files = JBBListDir(pdir);
			NSUInteger copied = 0;
			for (NSString *name in files) {
				if (![name hasSuffix:@".plist"]) continue;
				if (!options.includeApplePrefs && [name hasPrefix:@"com.apple."]) continue;
				NSString *dst = [[cDst stringByAppendingPathComponent:bid] stringByAppendingPathComponent:name];
				if (JBBCopyFileSafe([pdir stringByAppendingPathComponent:name], dst, warns)) copied++;
			}
			if (!copied) continue;
			res.prefsContainer += copied;
			res.containerHosts++;
			[map addObject:[NSString stringWithFormat:@"%@\t%@\t%@\t%lu",
							bid, [container lastPathComponent], container, (unsigned long)copied]];
			if ((res.containerHosts % 8) == 0) {
				JBBReport(progress, [NSString stringWithFormat:@"备份 App 沙盒配置…（已命中 %lu 个 App）", (unsigned long)res.containerHosts], 0.45);
			}
		}
		JBBWriteText([map componentsJoinedByString:@"\n"],
					 [cDst stringByAppendingPathComponent:@"_map.tsv"]);
		JBBWriteText([libDirs componentsJoinedByString:@"\n"],
					 [cDst stringByAppendingPathComponent:@"_library-dirs.tsv"]);
		JBBLog(@"App 沙盒：扫描 %lu 个容器，命中 %lu 个 App，拷贝 %lu 个配置文件",
			   (unsigned long)scanned, (unsigned long)res.containerHosts, (unsigned long)res.prefsContainer);
	} else {
		JBBLog(@"App 沙盒配置：已按设置跳过");
	}

	// ---------- 5. Application Support ----------
	if (options.includeAppSupport) {
		JBBReport(progress, @"备份 Application Support…", 0.68);
		NSString *apSrc = @"/var/mobile/Library/Application Support";
		NSString *apDst = [dir stringByAppendingPathComponent:@"prefs/appsupport"];
		JBBEnsureDir(apDst);
		NSMutableArray<NSString *> *apIndex = [NSMutableArray arrayWithObject:@"# /var/mobile/Library/Application Support 下的条目"];
		NSUInteger apCount = 0;
		for (NSString *name in JBBListDir(apSrc)) {
			if ([name hasPrefix:@"."]) continue;
			if (!options.includeApplePrefs && [name hasPrefix:@"com.apple."]) continue;
			NSString *src = [apSrc stringByAppendingPathComponent:name];
			NSString *dst = [apDst stringByAppendingPathComponent:name];
			BOOL isDir = NO;
			[[NSFileManager defaultManager] fileExistsAtPath:src isDirectory:&isDir];
			BOOL ok = isDir
				? JBBCopyDirSafe(src, dst, 8ULL * 1024ULL * 1024ULL, warns)
				: JBBCopyFileSafe(src, dst, warns);
			if (ok) { apCount++; [apIndex addObject:name]; }
		}
		JBBWriteText([apIndex componentsJoinedByString:@"\n"],
					 [apDst stringByAppendingPathComponent:@"_index.txt"]);
		JBBLog(@"Application Support：%lu 个条目", (unsigned long)apCount);
	}

	// ---------- 6. apt 缓存里的 deb ----------
	if (options.includeAptCache) {
		JBBReport(progress, @"备份 apt 缓存里的安装包…", 0.74);
		NSString *cacheDir = [jbroot stringByAppendingPathComponent:@"var/cache/apt/archives"];
		NSString *debDst = [dir stringByAppendingPathComponent:@"appcache"];
		NSUInteger debCount = 0;
		unsigned long long debBytes = 0;
		NSMutableArray<NSString *> *debIndex = [NSMutableArray arrayWithObject:@"# apt 缓存里的 .deb（有了它，重装不必联网）"];
		for (NSString *name in JBBListDir(cacheDir)) {
			if (![name hasSuffix:@".deb"]) continue;
			if (debCount >= 300) {
				[warns addObject:@"apt 缓存 deb 超过 300 个，剩余已跳过"];
				break;
			}
			NSString *src = [cacheDir stringByAppendingPathComponent:name];
			unsigned long long sz = JBBPathSize(src);
			if (debBytes + sz > 800ULL * 1024ULL * 1024ULL) {
				[warns addObject:@"apt 缓存 deb 总体积超过 800MB，剩余已跳过"];
				break;
			}
			if (JBBCopyFileSafe(src, [debDst stringByAppendingPathComponent:name], warns)) {
				debCount++;
				debBytes += sz;
				[debIndex addObject:name];
			}
		}
		if (debCount) {
			JBBWriteText([debIndex componentsJoinedByString:@"\n"],
						 [debDst stringByAppendingPathComponent:@"_index.txt"]);
		}
		res.aptCacheDebs = debCount;
		JBBLog(@"apt 缓存 deb：%lu 个（%@）", (unsigned long)debCount, JBBHumanSize(debBytes));
	}

	// ---------- 7. Documents 下的其它内容（可选） ----------
	if (options.includeMedia) {
		JBBReport(progress, @"备份 Documents 下的其它内容…", 0.79);
		NSString *mediaDst = [dir stringByAppendingPathComponent:@"media"];
		NSString *skipName = [outRoot lastPathComponent];     // 不把输出目录自己套进去
		unsigned long long copiedBytes = 0;
		for (NSString *name in JBBListDir(JBBMobileDocumentsDir())) {
			if ([name isEqualToString:skipName]) continue;
			if ([name hasPrefix:@"."]) continue;
			NSString *src = [JBBMobileDocumentsDir() stringByAppendingPathComponent:name];
			unsigned long long sz = JBBPathSize(src);
			if (copiedBytes + sz > 500ULL * 1024ULL * 1024ULL) {
				[warns addObject:[NSString stringWithFormat:@"Documents 备份总体积超过 500MB，%@ 起后续已跳过", name]];
				break;
			}
			BOOL isDir = NO;
			[[NSFileManager defaultManager] fileExistsAtPath:src isDirectory:&isDir];
			BOOL ok = isDir
				? JBBCopyDirSafe(src, [mediaDst stringByAppendingPathComponent:name], 200ULL * 1024ULL * 1024ULL, warns)
				: JBBCopyFileSafe(src, [mediaDst stringByAppendingPathComponent:name], warns);
			if (ok) copiedBytes += sz;
		}
		JBBLog(@"Documents 其它内容：已拷贝 %@", JBBHumanSize(copiedBytes));
	}

	// ---------- 8. manifest / 说明 / 还原脚本 ----------
	JBBReport(progress, @"生成清单与还原脚本…", 0.85);
	res.bytes = JBBPathSize(dir);

	NSDictionary *manifest = @{
		@"tool": JBB_VERSION,
		@"created": JBBISOTime(),
		@"machine": JBBDeviceMachine(),
		@"ios": JBBIOSVersion(),
		@"jbroot": jbroot,
		@"options": [options dictionaryRepresentation],
		@"counts": @{
			@"packagesTotal": @(res.packageTotal),
			@"packagesManual": @(res.packageManual),
			@"manualIsExact": @(res.manualIsExact),
			@"prefsGlobal": @(res.prefsGlobal),
			@"prefsContainer": @(res.prefsContainer),
			@"containerHosts": @(res.containerHosts),
			@"sourceFiles": @(res.sourceFiles),
			@"aptCacheDebs": @(res.aptCacheDebs),
		},
		@"bytesBeforeArchive": @(res.bytes),
		@"warnings": warns.count ? [warns copy] : @[],
	};
	JBBWritePlist(manifest, [dir stringByAppendingPathComponent:@"manifest.plist"]);

	JBBWriteText([self readmeTextForStamp:stamp], [dir stringByAppendingPathComponent:@"README.txt"]);
	JBBWriteText([self packagesScriptTextForStamp:stamp],
				 [dir stringByAppendingPathComponent:@"restore-packages.sh"]);
	JBBWriteText([self configsScriptTextForStamp:stamp],
				 [dir stringByAppendingPathComponent:@"restore-configs.sh"]);

	// ---------- 9. 打包 ----------
	JBBReport(progress, @"打包成 ZIP…", 0.90);
	res.archivePath = [self archiveBackupDirNamed:stamp];

	// ---------- 10. 双份写：iCloud Drive ----------
	JBBReport(progress, @"复制到 iCloud Drive…", 0.96);
	NSString *icloud = JBBIcloudRoot();
	if (JBBEnsureDir(icloud) && JBBPathWritable(icloud)) {
		NSString *src = res.archivePath ?: dir;
		NSString *dst = [icloud stringByAppendingPathComponent:[src lastPathComponent]];
		[[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
		NSError *err = nil;
		if ([[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&err]) {
			res.icloudPath = dst;
			JBBLog(@"iCloud 副本：%@", dst);
		} else {
			[warns addObject:[NSString stringWithFormat:@"iCloud 复制失败：%@", err.localizedDescription ?: @"未知"]];
		}
	} else {
		[warns addObject:@"iCloud Drive 目录不可写（没登录 iCloud 或被限制）→ 本次只写了本地一份"];
	}

	res.bytes = JBBPathSize(dir);
	res.warnings = warns.count ? [warns componentsJoinedByString:@"\n"] : @"";
	res.ok = YES;
	JBBLog(@"===== 备份完成：%@（目录 %@，归档 %@，iCloud %@）=====",
		   stamp, JBBHumanSize(res.bytes),
		   res.archivePath ? JBBHumanSize(JBBPathSize(res.archivePath)) : @"未生成",
		   res.icloudPath ?: @"无");

	JBBReport(progress, @"完成", 1.0);
	return res;
}

#pragma mark - 生成文本

+ (NSString *)readmeTextForStamp:(NSString *)stamp {
	return [NSString stringWithFormat:
		@"JBBackup 备份 %@（由 JBBackup %@ 生成）\n"
		@"\n"
		@"这个目录里有什么\n"
		@"  packages/packages-manual.txt   ← 你自己装的插件清单（name|version|section|origin）\n"
		@"  packages/packages-all.txt      ← 当时全部已安装的包（含系统基础包），仅作参照\n"
		@"  sources/                        ← 当时的 apt 源文件快照\n"
		@"  prefs/global/                   ← 全局插件配置（/var/mobile/Library/Preferences 下的 plist）\n"
		@"  prefs/containers/<bundleId>/    ← 各 App 沙盒内 Library/Preferences 的配置\n"
		@"  prefs/appsupport/               ← /var/mobile/Library/Application Support 下的插件数据\n"
		@"  appcache/                       ← apt 缓存里的 .deb（有它就能离线装回原版本）\n"
		@"  manifest.plist                  ← 备份时的环境信息与统计\n"
		@"  restore-packages.sh             ← 重装插件（要用 root 跑）\n"
		@"  restore-configs.sh              ← 手工还原全局配置（推荐改用 App 里的「还原配置」）\n"
		@"\n"
		@"重新越狱之后怎么恢复\n"
		@"  第 1 步  把「插件装回来」\n"
		@"     用 NewTerm 3 / SSH 以 root 身份执行：\n"
		@"         sh \"<本目录>/restore-packages.sh\"\n"
		@"     它会自动探测 jbroot、补回 apt 源、apt update，然后逐个重装。\n"
		@"\n"
		@"  第 2 步  把「配置还原回去」\n"
		@"     打开 JBBackup App → 还原 → 选这个备份 → 「还原配置」\n"
		@"     （推荐用 App：它会按 bundle id 重新定位 App 容器 —— 重装 App 后容器 UUID 会变，\n"
		@"       手工拷贝到旧 UUID 目录是无效的。）\n"
		@"\n"
		@"  第 3 步  注销桌面（respring）\n"
		@"\n"
		@"⚠️ 重要\n"
		@"  · 这个备份目录必须放到「抹机之后还能活下来」的位置：iCloud Drive、电脑、微信文件传输。\n"
		@"    放在 /var/mobile/Documents 里的话，抹掉所有内容和设置会被一起清掉。\n"
		@"  · JBBackup 不会删除你的任何文件；还原配置前它会把「当前的配置」另存一份到\n"
		@"    /var/mobile/Documents/JBBackup/_restore-safety-<时间戳>/ 以防万一。\n",
		stamp, JBB_VERSION];
}

+ (NSString *)packagesScriptTextForStamp:(NSString *)stamp {
	return [NSString stringWithFormat:
		@"#!/bin/sh\n"
		@"# ============================================================\n"
		@"#  JBBackup 生成的「插件重装」脚本\n"
		@"#  备份时间：%@\n"
		@"#  ⚠️ 必须用 root 执行！普通用户装不了包。\n"
		@"#\n"
		@"#  用法（重新越狱之后）：\n"
		@"#    方法 A：NewTerm 3 里先 su 到 root，再执行\n"
		@"#            sh \"<本脚本完整路径>\"\n"
		@"#    方法 B：SSH 登录（ssh root@127.0.0.1，密码默认 alpine）后执行\n"
		@"#\n"
		@"#  这个脚本只做四件事：探测 jbroot → 补回 apt 源 → apt update → 逐个重装。\n"
		@"#  它【不会】删除任何东西，也不会动系统基础包。\n"
		@"# ============================================================\n"
		@"set -u\n"
		@"\n"
		@"HERE=$(cd \"$(dirname \"$0\")\" && pwd)\n"
		@"\n"
		@"# ---------- 1. 自动探测 jbroot ----------\n"
		@"JB=\"\"\n"
		@"for c in \"${JBROOT:-}\" /var/containers/Bundle/Application/.jbroot-* /var/jb /; do\n"
		@"    if [ -n \"$c\" ] && [ -f \"$c/var/lib/dpkg/status\" ]; then JB=\"$c\"; break; fi\n"
		@"done\n"
		@"if [ -z \"$JB\" ]; then\n"
		@"    echo \"X 没找到越狱环境（jbroot）。请确认已经重新越狱。\"\n"
		@"    exit 1\n"
		@"fi\n"
		@"echo \"OK jbroot = $JB\"\n"
		@"\n"
		@"APT=\"$JB/usr/bin/apt-get\"; [ -x \"$APT\" ] || APT=\"$JB/bin/apt-get\"\n"
		@"DPKG=\"$JB/usr/bin/dpkg\";   [ -x \"$DPKG\" ] || DPKG=\"$JB/bin/dpkg\"\n"
		@"\n"
		@"# ---------- 2. 补回 apt 源 ----------\n"
		@"if [ -d \"$HERE/sources\" ]; then\n"
		@"    echo \"==> 补回 apt 源\"\n"
		@"    mkdir -p \"$JB/etc/apt/sources.list.d\"\n"
		@"    for f in \"$HERE/sources\"/*; do\n"
		@"        [ -f \"$f\" ] || continue\n"
		@"        b=$(basename \"$f\")\n"
		@"        case \"$b\" in\n"
		@"            _*) continue ;;\n"
		@"            sources.list) cp -f \"$f\" \"$JB/etc/apt/sources.list\" ;;\n"
		@"            *)            cp -f \"$f\" \"$JB/etc/apt/sources.list.d/\" ;;\n"
		@"        esac\n"
		@"        echo \"    + $b\"\n"
		@"    done\n"
		@"fi\n"
		@"\n"
		@"# ---------- 3. 更新索引 ----------\n"
		@"if [ -x \"$APT\" ]; then\n"
		@"    echo \"==> apt update（需要联网）\"\n"
		@"    \"$APT\" -y update || echo \"    !! update 有报错，继续尝试装包\"\n"
		@"fi\n"
		@"\n"
		@"# ---------- 4. 逐个重装 ----------\n"
		@"LIST=\"$HERE/packages/packages-manual.txt\"\n"
		@"[ -f \"$LIST\" ] || LIST=\"$HERE/packages/packages-all.txt\"\n"
		@"if [ ! -f \"$LIST\" ]; then echo \"X 找不到包列表\"; exit 1; fi\n"
		@"\n"
		@"OK=0; FAIL=0\n"
		@"while IFS='|' read -r NAME VER SEC ORG; do\n"
		@"    case \"$NAME\" in ''|\\#*) continue ;; esac\n"
		@"    echo \"==> $NAME  ($VER)\"\n"
		@"    if [ -x \"$APT\" ]; then\n"
		@"        if \"$APT\" -y --reinstall install \"$NAME\"; then OK=$((OK+1)); else FAIL=$((FAIL+1)); fi\n"
		@"    elif [ -x \"$DPKG\" ]; then\n"
		@"        if \"$DPKG\" -i \"$NAME\"; then OK=$((OK+1)); else FAIL=$((FAIL+1)); fi\n"
		@"    else\n"
		@"        echo \"X 既没有 apt-get 也没有 dpkg\"; break\n"
		@"    fi\n"
		@"done < \"$LIST\"\n"
		@"\n"
		@"echo \"\"\n"
		@"echo \"================ 完成 ================\"\n"
		@"echo \"成功 $OK 个，失败 $FAIL 个\"\n"
		@"echo \"失败的多半是源里已经没有那个版本了 —— 打开 Sileo 搜名字手动装即可。\"\n"
		@"echo \"\"\n"
		@"echo \"下一步：打开 JBBackup App → 还原 → 还原配置；然后注销桌面。\"\n",
		stamp];
}

+ (NSString *)configsScriptTextForStamp:(NSString *)stamp {
	return [NSString stringWithFormat:
		@"#!/bin/sh\n"
		@"# ============================================================\n"
		@"#  JBBackup 生成的「全局配置还原」脚本（备份时间：%@）\n"
		@"#\n"
		@"#  ⚠️ 这是最坏情况下的手工兜底。优先用 JBBackup App 里的「还原配置」按钮，\n"
		@"#     因为 App 还会处理「各 App 沙盒内的配置」——那需要按 bundle id 重新定位容器\n"
		@"#     （重装 App 后容器 UUID 会变），shell 脚本做不到这件事。\n"
		@"#\n"
		@"#  本脚本只还原 /var/mobile/Library/Preferences 下的全局配置。\n"
		@"#  覆盖前会把现状另存一份，不会静默丢数据。\n"
		@"# ============================================================\n"
		@"set -u\n"
		@"HERE=$(cd \"$(dirname \"$0\")\" && pwd)\n"
		@"SRC=\"$HERE/prefs/global\"\n"
		@"PREF=/var/mobile/Library/Preferences\n"
		@"SAFE=/var/mobile/Documents/JBBackup/_restore-safety-$(date +%%Y%%m%%d-%%H%%M%%S)\n"
		@"\n"
		@"[ -d \"$SRC\" ] || { echo \"X 找不到 $SRC\"; exit 1; }\n"
		@"mkdir -p \"$SAFE/global\"\n"
		@"echo \"==> 先把当前配置另存一份到 $SAFE\"\n"
		@"cp -a \"$PREF\"/*.plist \"$SAFE/global/\" 2>/dev/null\n"
		@"\n"
		@"N=0\n"
		@"for f in \"$SRC\"/*.plist; do\n"
		@"    [ -f \"$f\" ] || continue\n"
		@"    b=$(basename \"$f\")\n"
		@"    cp -f \"$f\" \"$PREF/$b\" && N=$((N+1))\n"
		@"done\n"
		@"echo \"==> 已还原 $N 个全局配置文件\"\n"
		@"echo \"\"\n"
		@"echo \"各 App 沙盒内的配置请用 JBBackup App 的「还原配置」按钮处理。\"\n"
		@"echo \"完成后注销桌面：killall -9 SpringBoard\"\n",
		stamp];
}

@end
