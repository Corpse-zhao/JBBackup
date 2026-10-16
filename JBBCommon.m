//
//  JBBCommon.m
//

#import "JBBCommon.h"
#import <time.h>

#pragma mark - 日志

static NSString *sLogPath = nil;
static BOOL sLogPathResolved = NO;
static NSMutableString *sLogBuf = nil;      // 内存里保留最近一段，供界面展示/复制
static NSLock *sLogLock = nil;              // ⚠️ 备份在后台队列跑、界面在主线程读日志 → 必须加锁

static NSLock *JBBLogLock(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{ sLogLock = [[NSLock alloc] init]; });
	return sLogLock;
}

NSString *JBBLogPath(void) {
	if (sLogPathResolved) return sLogPath;
	sLogPathResolved = YES;
	// ⚠️ 这里绝不能调 JBBLog，否则递归。只算路径，不建目录。
	sLogPath = [JBBOutputRoot() stringByAppendingPathComponent:@"_jbbackup.log"];
	return sLogPath;
}

static void JBBStampNow(char *out, size_t n) {
	time_t t = time(NULL);
	struct tm tmv;
	memset(&tmv, 0, sizeof(tmv));
	localtime_r(&t, &tmv);
	strftime(out, n, "%H:%M:%S", &tmv);
}

static void JBBLogAppend(NSString *line) {
	NSLock *lock = JBBLogLock();
	[lock lock];
	if (!sLogBuf) sLogBuf = [[NSMutableString alloc] init];
	[sLogBuf appendString:line];
	// 内存缓冲封顶 64K：只留最新的一段，避免长时间运行吃内存
	if (sLogBuf.length > 64 * 1024) {
		[sLogBuf deleteCharactersInRange:NSMakeRange(0, sLogBuf.length - 64 * 1024)];
	}
	[lock unlock];

	NSString *path = JBBLogPath();
	if (!path.length) return;

	@try {
		NSFileManager *fm = [NSFileManager defaultManager];
		NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
		if (!data) return;
		if (![fm fileExistsAtPath:path]) {
			[data writeToFile:path atomically:YES];
			return;
		}
		// ⚠️ 日志必须封顶：追加式日志长时间会涨到几百 MB，
		//    用户回传时读取工具都打不开（历史踩过 265MB 的坑）。
		unsigned long long size = [[fm attributesOfItemAtPath:path error:NULL] fileSize];
		if (size > 512ULL * 1024ULL) {
			[data writeToFile:path atomically:YES];   // 超限 → 整份重写
			return;
		}
		NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:path];
		if (handle) {
			[handle seekToEndOfFile];
			[handle writeData:data];
			[handle closeFile];
		} else {
			[data writeToFile:path atomically:YES];
		}
	} @catch (NSException *e) {
		// 日志失败绝不能影响主流程
	}
}

void JBBLog(NSString *fmt, ...) {
	if (!fmt) return;
	va_list ap;
	va_start(ap, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	if (!msg) return;

	char stamp[16];
	JBBStampNow(stamp, sizeof(stamp));
	NSString *line = [NSString stringWithFormat:@"[%s] %@\n", stamp, msg];
	NSLog(@"[JBBackup] %@", msg);
	JBBLogAppend(line);
}

NSString *JBBLogTail(NSUInteger maxChars) {
	NSLock *lock = JBBLogLock();
	[lock lock];
	NSString *buf = sLogBuf ? [sLogBuf copy] : @"";
	[lock unlock];
	if (buf.length <= maxChars) return buf;
	return [buf substringFromIndex:buf.length - maxChars];
}

void JBBLogClear(void) {
	NSLock *lock = JBBLogLock();
	[lock lock];
	if (sLogBuf) [sLogBuf setString:@""];
	[lock unlock];
	NSString *path = JBBLogPath();
	if (path.length) {
		[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	}
}

#pragma mark - 越狱环境

static NSString *sJBRoot = nil;
static BOOL sJBProbed = NO;

/// jbroot 的判据：里面必须有 dpkg 的包数据库。凭空猜路径不可靠，必须验这个文件。
static BOOL JBBLooksLikeJBRoot(NSString *path) {
	if (!path.length) return NO;
	NSString *status = [path stringByAppendingPathComponent:@"var/lib/dpkg/status"];
	return [[NSFileManager defaultManager] fileExistsAtPath:status];
}

NSString *JBBJBRoot(void) {
	if (sJBProbed) return sJBRoot;
	sJBProbed = YES;
	NSFileManager *fm = [NSFileManager defaultManager];

	// ① 环境变量（越狱环境 spawn 出来的进程才带，命中率不高但要先试）
	NSArray<NSString *> *envKeys = @[ @"JBROOT", @"JBROOT_PATH", @"THEOS_JBROOT", @"JB_SANDBOX_EXTENSIONS" ];
	for (NSString *key in envKeys) {
		const char *v = getenv([key UTF8String]);
		if (!v) continue;
		NSString *cand = [NSString stringWithUTF8String:v];
		if (JBBLooksLikeJBRoot(cand)) {
			sJBRoot = cand;
			return sJBRoot;
		}
	}

	// ② 从自己所在路径反推（deb 装进 jbroot 时最准）
	//    $JBROOT/Applications/JBBackup.app  →  去掉最后两段就是 $JBROOT
	NSString *bundle = [[NSBundle mainBundle] bundlePath];
	NSArray<NSString *> *parts = [bundle pathComponents];
	if (parts.count >= 4) {
		NSString *cand = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, parts.count - 2)]];
		if (JBBLooksLikeJBRoot(cand)) {
			sJBRoot = cand;
			return sJBRoot;
		}
	}

	// ③ roothide 的 jbroot 名字是随机化的 .jbroot-XXXXXXXX，直接扫描常见父目录
	NSArray<NSString *> *bases = @[
		@"/var/containers/Bundle/Application",
		@"/private/var/containers/Bundle/Application",
		@"/var/mobile/Library",
		@"/var/mobile",
		@"/var",
	];
	for (NSString *base in bases) {
		NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:base error:NULL];
		for (NSString *name in names) {
			if (![name hasPrefix:@".jbroot"]) continue;
			NSString *full = [base stringByAppendingPathComponent:name];
			if (JBBLooksLikeJBRoot(full)) {
				sJBRoot = full;
				return sJBRoot;
			}
		}
	}

	// ④ rootless 的固定路径兜底
	if (JBBLooksLikeJBRoot(@"/var/jb")) {
		sJBRoot = @"/var/jb";
		return sJBRoot;
	}

	sJBRoot = nil;
	return nil;
}

BOOL JBBJBReady(void) {
	NSString *root = JBBJBRoot();
	if (!root.length) return NO;
	return JBBLooksLikeJBRoot(root);
}

NSString *JBBEnvSummary(void) {
	NSMutableString *s = [NSMutableString string];
	NSString *root = JBBJBRoot();
	if (!root.length) {
		[s appendString:@"❌ 未探测到越狱环境（jbroot 里没有 dpkg 数据库）\n"];
		[s appendString:@"   → 备份功能不可用。若你确实在越狱环境下，请把本页日志发给作者。\n"];
		return s;
	}
	[s appendFormat:@"jbroot：%@\n", root];
	[s appendFormat:@"dpkg 库：%@\n", [root stringByAppendingPathComponent:@"var/lib/dpkg/status"]];
	[s appendFormat:@"已安装包：%lu 个\n", (unsigned long)[JBBInstalledPackages() count]];
	[s appendFormat:@"手动安装：%lu 个\n", (unsigned long)[JBBManualPackageNames() count]];
	[s appendFormat:@"apt 源文件：%lu 个\n", (unsigned long)[JBBSourceFilePaths() count]];
	[s appendFormat:@"App 容器：%lu 个\n", (unsigned long)[JBBAppContainerPaths() count]];
	[s appendFormat:@"输出目录：%@（%@）\n", JBBOutputRoot(),
		JBBPathWritable(JBBOutputRoot()) ? @"可写" : @"不可写"];
	[s appendFormat:@"iCloud：%@（%@）\n", JBBIcloudRoot(),
		JBBPathWritable(JBBIcloudRoot()) ? @"可写" : @"不可用"];
	[s appendFormat:@"剩余空间：%@\n", JBBHumanSize(JBBFreeBytes(JBBOutputRoot()))];
	return s;
}

#pragma mark - 路径

NSString *JBBMobileDocumentsDir(void) {
	return @"/var/mobile/Documents";
}

NSString *JBBOutputRoot(void) {
	return [JBBMobileDocumentsDir() stringByAppendingPathComponent:@"JBBackup"];
}

NSString *JBBIcloudRoot(void) {
	return @"/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/JBBackup";
}

BOOL JBBEnsureDir(NSString *path) {
	if (!path.length) return NO;
	if (JBBFileExists(path)) return YES;
	NSError *err = nil;
	BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:path
									   withIntermediateDirectories:YES
														attributes:nil
															 error:&err];
	return ok;
}

BOOL JBBPathWritable(NSString *path) {
	if (!JBBEnsureDir(path)) return NO;
	NSString *probe = [path stringByAppendingPathComponent:@".jbb_write_probe"];
	BOOL ok = [@"probe" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	if (ok) [[NSFileManager defaultManager] removeItemAtPath:probe error:NULL];
	return ok;
}

#pragma mark - 文件

BOOL JBBFileExists(NSString *path) {
	if (!path.length) return NO;
	return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

NSString *JBBReadText(NSString *path) {
	if (!JBBFileExists(path)) return nil;
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (!data) return nil;
	NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if (s) return s;
	return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

BOOL JBBWriteText(NSString *text, NSString *path) {
	if (!path.length) return NO;
	if (!text) text = @"";
	return [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

BOOL JBBWriteData(NSData *data, NSString *path) {
	if (!data || !path.length) return NO;
	return [data writeToFile:path atomically:YES];
}

NSDictionary *JBBReadPlist(NSString *path) {
	if (!JBBFileExists(path)) return nil;
	id obj = [NSDictionary dictionaryWithContentsOfFile:path];
	if ([obj isKindOfClass:[NSDictionary class]]) return obj;
	return nil;
}

BOOL JBBWritePlist(NSDictionary *dict, NSString *path) {
	if (!dict || !path.length) return NO;
	// plist 一律写 XML（人可在 Filza 里直接看/改，也便于跨版本解析）
	NSError *err = nil;
	NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
															 format:NSPropertyListXMLFormat_v1_0
															options:0
															  error:&err];
	if (!data) return NO;
	return [data writeToFile:path atomically:YES];
}

unsigned long long JBBPathSize(NSString *path) {
	if (!path.length) return 0;
	NSFileManager *fm = [NSFileManager defaultManager];
	BOOL isDir = NO;
	if (![fm fileExistsAtPath:path isDirectory:&isDir]) return 0;
	if (!isDir) return [[fm attributesOfItemAtPath:path error:NULL] fileSize];

	unsigned long long total = 0;
	NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:path error:NULL];
	for (NSString *name in names) {
		total += JBBPathSize([path stringByAppendingPathComponent:name]);
	}
	return total;
}

unsigned long long JBBFreeBytes(NSString *path) {
	NSString *probe = path.length ? path : @"/var/mobile";
	struct statfs st;
	memset(&st, 0, sizeof(st));
	if (statfs([probe fileSystemRepresentation], &st) != 0) return 0;
	return (unsigned long long)st.f_bavail * (unsigned long long)st.f_bsize;
}

NSArray<NSString *> *JBBListDir(NSString *dir) {
	if (!dir.length) return @[];
	NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
	if (![names isKindOfClass:[NSArray class]]) return @[];
	return names;
}

#pragma mark - 已安装包

/// 解析 dpkg 文本型数据库（status / extended_states 共用同一套「空行分段 + Key: Value」格式）
static NSArray<NSDictionary *> *JBBParseDpkgDB(NSString *text) {
	NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
	if (!text.length) return out;
	NSMutableDictionary *cur = [NSMutableDictionary dictionary];
	NSString *curKey = nil;
	NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
	for (NSString *line in lines) {
		if (line.length == 0) {
			if (cur.count) [out addObject:[cur copy]];
			[cur removeAllObjects];
			curKey = nil;
			continue;
		}
		if ([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) {
			if (curKey && cur[curKey]) {   // 续行
				cur[curKey] = [cur[curKey] stringByAppendingString:line];
			}
			continue;
		}
		NSRange colon = [line rangeOfString:@":"];
		if (colon.location == NSNotFound) continue;
		NSString *key = [line substringToIndex:colon.location];
		NSString *val = [[line substringFromIndex:colon.location + 1]
						 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		cur[key] = val;
		curKey = key;
	}
	if (cur.count) [out addObject:[cur copy]];
	return out;
}

NSArray<NSDictionary *> *JBBInstalledPackages(void) {
	NSString *root = JBBJBRoot();
	if (!root.length) return @[];
	NSString *path = [root stringByAppendingPathComponent:@"var/lib/dpkg/status"];
	NSArray<NSDictionary *> *all = JBBParseDpkgDB(JBBReadText(path));

	NSMutableArray<NSDictionary *> *res = [NSMutableArray array];
	for (NSDictionary *p in all) {
		NSString *status = p[@"Status"] ?: @"";
		if ([status rangeOfString:@"install ok installed"].location == NSNotFound) continue;
		NSString *name = p[@"Package"] ?: @"";
		if (!name.length) continue;
		[res addObject:@{
			@"name": name,
			@"version": p[@"Version"] ?: @"",
			@"section": p[@"Section"] ?: @"",
			@"origin": p[@"Origin"] ?: @"",
			@"maintainer": p[@"Maintainer"] ?: @"",
			@"size": p[@"Installed-Size"] ?: @"0",
		}];
	}
	return res;
}

/// bootstrap 自带的基础包（仅在 apt 的 extended_states 缺失时才用于兜底过滤）
static NSArray<NSString *> *JBBBasePackageHints(void) {
	return @[
		@"base", @"firmware", @"bash", @"dash", @"zsh", @"coreutils", @"libcoreutils",
		@"dpkg", @"apt", @"libapt-pkg6.0", @"libapt", @"grep", @"sed", @"gawk",
		@"findutils", @"tar", @"gzip", @"bzip2", @"xz-utils", @"liblzma5", @"zstd",
		@"curl", @"libcurl4", @"openssl", @"libssl1.1", @"libssl3", @"ca-certificates",
		@"sileo", @"zebra", @"procursus-keyring", @"roothide-keyring", @"roothide",
		@"libroothide", @"libroot", @"libsandy", @"libkrw", @"libhooker",
		@"mobilesubstrate", @"preferenceloader", @"ellekit", @"injector",
		@"launchctl", @"profile.d", @"libedit0", @"libncursesw6", @"libpcre2-8-0",
		@"libzstd1", @"librust", @"uikittools", @"uikittools-extra", @"firmware-sbin",
		@"iphoneos-arm64e-meeles", @"shell-cmds", @"bc", @"less", @"nano", @"vim",
	];
}

NSArray<NSString *> *JBBManualPackageNames(void) {
	NSString *root = JBBJBRoot();
	if (!root.length) return @[];

	// 先拿到「确实处于已安装状态」的集合
	NSMutableSet<NSString *> *installed = [NSMutableSet set];
	for (NSDictionary *p in JBBInstalledPackages()) {
		NSString *n = p[@"name"];
		if (n.length) [installed addObject:n];
	}

	// ① 首选：apt 的 extended_states（Auto-Installed: 0 = 用户手动装的）
	NSString *ext = [root stringByAppendingPathComponent:@"var/lib/apt/extended_states"];
	NSArray<NSDictionary *> *segs = JBBParseDpkgDB(JBBReadText(ext));
	NSMutableArray<NSString *> *manual = [NSMutableArray array];
	for (NSDictionary *seg in segs) {
		NSString *name = seg[@"Package"] ?: @"";
		if (!name.length || ![installed containsObject:name]) continue;
		NSString *autoInst = seg[@"Auto-Installed"] ?: @"0";
		if ([autoInst isEqualToString:@"1"]) continue;      // 1 = 作为依赖被自动安装
		[manual addObject:name];
	}
	if (manual.count) return [manual sortedArrayUsingSelector:@selector(compare:)];

	// ② 兜底：extended_states 不存在/为空时，用「全部已安装 − 基础包名提示表」近似
	NSSet<NSString *> *hints = [NSSet setWithArray:JBBBasePackageHints()];
	NSMutableArray<NSString *> *guess = [NSMutableArray array];
	for (NSString *n in installed) {
		if ([hints containsObject:n]) continue;
		[guess addObject:n];
	}
	return [guess sortedArrayUsingSelector:@selector(compare:)];
}

NSArray<NSString *> *JBBSourceFilePaths(void) {
	NSString *root = JBBJBRoot();
	if (!root.length) return @[];
	NSMutableArray<NSString *> *out = [NSMutableArray array];

	NSString *main_list = [root stringByAppendingPathComponent:@"etc/apt/sources.list"];
	if (JBBFileExists(main_list)) [out addObject:main_list];

	NSArray<NSString *> *dirs = @[
		[root stringByAppendingPathComponent:@"etc/apt/sources.list.d"],
		[root stringByAppendingPathComponent:@"etc/apt/preferences.d"],
	];
	for (NSString *dir in dirs) {
		for (NSString *name in JBBListDir(dir)) {
			NSString *lower = [name lowercaseString];
			if (![lower hasSuffix:@".list"] && ![lower hasSuffix:@".sources"] &&
				![lower hasSuffix:@".conf"]) continue;
			[out addObject:[dir stringByAppendingPathComponent:name]];
		}
	}
	return out;
}

#pragma mark - App 容器

NSString *JBBContainerBundleID(NSString *containerPath) {
	if (!containerPath.length) return nil;
	NSString *meta = [containerPath stringByAppendingPathComponent:
					  @".com.apple.mobile_container_manager.metadata.plist"];
	NSDictionary *d = JBBReadPlist(meta);
	NSString *bid = d[@"MCMMetadataIdentifier"];
	if ([bid isKindOfClass:[NSString class]] && bid.length) return bid;
	return nil;
}

NSArray<NSString *> *JBBAppContainerPaths(void) {
	NSString *base = @"/var/mobile/Containers/Data/Application";
	NSMutableArray<NSString *> *out = [NSMutableArray array];
	for (NSString *name in JBBListDir(base)) {
		if (!name.length || [name hasPrefix:@"."]) continue;
		[out addObject:[base stringByAppendingPathComponent:name]];
	}
	return out;
}

#pragma mark - 工具调用

NSString *JBBFindTool(NSArray<NSString *> *candidates) {
	NSFileManager *fm = [NSFileManager defaultManager];
	for (NSString *path in candidates) {
		if (!path.length) continue;
		if ([fm isExecutableFileAtPath:path]) return path;
	}
	return nil;
}

BOOL JBBRunTool(NSString *tool, NSArray<NSString *> *args, NSString **outText) {
	if (!tool.length) return NO;
	if (![[NSFileManager defaultManager] isExecutableFileAtPath:tool]) return NO;

	int fds[2] = { -1, -1 };
	if (pipe(fds) != 0) return NO;

	posix_spawn_file_actions_t fa;
	posix_spawn_file_actions_init(&fa);
	posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&fa, fds[1], STDERR_FILENO);
	posix_spawn_file_actions_addclose(&fa, fds[0]);

	char *argv[64];
	int argc = 0;
	argv[argc++] = (char *)[tool UTF8String];
	for (NSString *a in args) {
		if (argc >= 62) break;                 // 留出 argv[argc]=NULL 的位置
		argv[argc++] = (char *)[a UTF8String];
	}
	argv[argc] = NULL;

	extern char **environ;
	pid_t pid = 0;
	int rc = posix_spawn(&pid, [tool UTF8String], &fa, NULL, argv, environ);
	posix_spawn_file_actions_destroy(&fa);
	close(fds[1]);

	if (rc != 0) {
		close(fds[0]);
		if (outText) *outText = [NSString stringWithFormat:@"posix_spawn 失败 rc=%d", rc];
		return NO;
	}

	NSMutableData *out = [NSMutableData data];
	char buf[4096];
	ssize_t n = 0;
	while ((n = read(fds[0], buf, sizeof(buf))) > 0) {
		[out appendBytes:buf length:(NSUInteger)n];
		if (out.length > 512 * 1024) break;    // 捕获上限，防被工具刷爆内存
	}
	close(fds[0]);

	int st = 0;
	waitpid(pid, &st, 0);

	if (outText) {
		NSString *s = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
		*outText = s ?: @"";
	}
	return (WIFEXITED(st) && WEXITSTATUS(st) == 0);
}

#pragma mark - 杂项

NSString *JBBHumanSize(unsigned long long bytes) {
	if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
	if (bytes < 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
	if (bytes < 1024ULL * 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
	return [NSString stringWithFormat:@"%.2f GB", (double)bytes / (1024.0 * 1024.0 * 1024.0)];
}

NSString *JBBTimestampString(void) {
	time_t t = time(NULL);
	struct tm tmv;
	memset(&tmv, 0, sizeof(tmv));
	localtime_r(&t, &tmv);
	char buf[32];
	strftime(buf, sizeof(buf), "%Y%m%d-%H%M%S", &tmv);
	return [NSString stringWithUTF8String:buf] ?: @"19700101-000000";
}

BOOL JBBRespring(void) {
	// SpringBoard 以 mobile 身份运行，本 App 已是 no-sandbox，可以直接 kill。
	// 不同越狱环境 killall 位置不同，逐个探测。
	NSString *root = JBBJBRoot() ?: @"";
	NSMutableArray<NSString *> *cands = [NSMutableArray array];
	if (root.length) {
		[cands addObject:[root stringByAppendingPathComponent:@"usr/bin/killall"]];
		[cands addObject:[root stringByAppendingPathComponent:@"bin/killall"]];
	}
	[cands addObject:@"/usr/bin/killall"];
	[cands addObject:@"/bin/killall"];

	NSString *tool = JBBFindTool(cands);
	if (!tool.length) {
		JBBLog(@"注销失败：找不到 killall");
		return NO;
	}
	NSString *out = nil;
	BOOL ok = JBBRunTool(tool, @[ @"-9", @"SpringBoard" ], &out);
	JBBLog(@"注销桌面：killall -9 SpringBoard → %@ %@", ok ? @"已发出" : @"失败", out ?: @"");
	if (!ok) {
		// 兜底：直接 kill(pid)（SpringBoard 与我们是同一个 uid，允许）
		pid_t pid = 0;
		NSString *ps = JBBFindTool(root.length
			? @[ [root stringByAppendingPathComponent:@"usr/bin/pgrep"], @"/usr/bin/pgrep" ]
			: @[ @"/usr/bin/pgrep" ]);
		if (ps.length) {
			NSString *pg = nil;
			if (JBBRunTool(ps, @[ @"-x", @"SpringBoard" ], &pg)) {
				pid = (pid_t)atoi([pg UTF8String]);
			}
		}
		if (pid > 0) {
			kill(pid, SIGKILL);
			JBBLog(@"注销桌面：兜底 kill(%d, SIGKILL)", (int)pid);
			return YES;
		}
	}
	return ok;
}

void JBBCopyToPasteboard(NSString *text) {
	if (!text) return;
#ifdef JBB_HAS_UIKIT
	[UIPasteboard generalPasteboard].string = text;
#else
	// 非 iOS 宿主（CI 里的 ZIP 往返自测）：没有剪贴板，静默跳过。
	// 不写日志 —— 这条路径只在测试环境出现，不需要污染日志。
	(void)text;
#endif
}
