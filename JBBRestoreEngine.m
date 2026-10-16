//
//  JBBRestoreEngine.m
//  JBBackup —— 还原引擎
//
//  设计要点（都不是拍脑袋的）：
//   1. 还原【必须】在重新越狱之后做 —— 没有 jbroot 时直接拒绝，不做任何写入。
//   2. 覆盖前先把「现状」另存到 _restore-safety-<时间戳>/，绝不静默丢数据。
//   3. App 沙盒配置按 bundle id 重新定位容器 —— 重装 App 后容器 UUID 会变，
//      照着备份里的旧 UUID 路径粘回去等于扔进垃圾桶。
//   4. 只覆盖备份里「确实有的」文件，不删除任何其它东西。
//   5. 本地没有备份目录时，自动去 iCloud Drive 找同名目录 / 同名 tar.gz 回捞。
//

#import "JBBRestoreEngine.h"
#import "JBBCommon.h"

#pragma mark - 结果

@implementation JBBRestoreResult
@end

#pragma mark - 工具

static void JBBRReport(JBBProgressBlock progress, NSString *stage, double fraction) {
	if (!progress) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		progress(stage, fraction);
	});
}

/// 复制单个文件（覆盖目标，目标父目录自动建）
static BOOL JBBRCopyFile(NSString *src, NSString *dst, NSMutableArray<NSString *> *warns) {
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
	if (warns) [warns addObject:[NSString stringWithFormat:@"写入失败 %@（%@）",
								 [dst lastPathComponent], err.localizedDescription ?: @"未知"]];
	return NO;
}

/// 复制整个目录（覆盖目标）
static BOOL JBBRCopyDir(NSString *src, NSString *dst, NSMutableArray<NSString *> *warns) {
	NSFileManager *fm = [NSFileManager defaultManager];
	BOOL isDir = NO;
	if (![fm fileExistsAtPath:src isDirectory:&isDir] || !isDir) return NO;
	if (!JBBEnsureDir([dst stringByDeletingLastPathComponent])) return NO;
	[fm removeItemAtPath:dst error:NULL];
	NSError *err = nil;
	if ([fm copyItemAtPath:src toPath:dst error:&err]) return YES;
	if (warns) [warns addObject:[NSString stringWithFormat:@"写入目录失败 %@（%@）",
								 [dst lastPathComponent], err.localizedDescription ?: @"未知"]];
	return NO;
}

/// 把「即将被覆盖的现状」另存到安全目录里（file: 单文件 / dir: 整个目录）
static void JBBRSafetyKeep(NSString *existingPath, NSString *safetyDir, BOOL isDir,
						   NSMutableArray<NSString *> *notes) {
	if (!existingPath.length || !safetyDir.length) return;
	if (!JBBFileExists(existingPath)) return;                    // 现状本来就没有 → 没什么可保
	NSString *dst = [safetyDir stringByAppendingPathComponent:[existingPath lastPathComponent]];
	if (JBBFileExists(dst)) return;                              // 已经保过一份，不重复
	BOOL ok = isDir ? JBBRCopyDir(existingPath, dst, nil) : JBBRCopyFile(existingPath, dst, nil);
	if (ok && notes) {
		[notes addObject:[existingPath lastPathComponent]];
	}
}

/// 真正解析出的备份源目录（本地优先；本地没有则从 iCloud 回捞）
@interface JBBRSource : NSObject
@property (nonatomic, copy) NSString *dir;
@property (nonatomic, copy) NSString *note;      ///< 给用户看的来源说明
@property (nonatomic, assign) BOOL ok;
@end
@implementation JBBRSource
@end

static JBBRSource *JBBRResolveSource(NSString *name) {
	JBBRSource *s = [[JBBRSource alloc] init];
	NSString *local = [JBBBackupEngine pathForBackupName:name];
	if (JBBFileExists(local)) {
		s.dir = local;
		s.note = @"本地备份目录";
		s.ok = YES;
		return s;
	}

	// 本地没有 → 去 iCloud 找
	NSString *icloud = JBBIcloudRoot();
	NSString *icloudDir = [icloud stringByAppendingPathComponent:name];
	if (JBBFileExists(icloudDir)) {
		s.dir = icloudDir;
		s.note = @"iCloud Drive 里的备份目录";
		s.ok = YES;
		return s;
	}

	NSString *archive = [icloud stringByAppendingPathComponent:
						 [name stringByAppendingPathExtension:@"tar.gz"]];
	if (!JBBFileExists(archive)) {
		s.ok = NO;
		s.note = [NSString stringWithFormat:@"本地与 iCloud 都找不到备份「%@」", name];
		return s;
	}

	// 解包到本地一个临时工作目录
	NSString *work = [JBBOutputRoot() stringByAppendingPathComponent:
					  [NSString stringWithFormat:@"_icloud-%@", name]];
	JBBEnsureDir(work);
	NSString *jb = JBBJBRoot() ?: @"";
	NSMutableArray<NSString *> *cands = [NSMutableArray array];
	if (jb.length) {
		[cands addObject:[jb stringByAppendingPathComponent:@"usr/bin/tar"]];
		[cands addObject:[jb stringByAppendingPathComponent:@"bin/tar"]];
	}
	[cands addObject:@"/usr/bin/tar"];
	[cands addObject:@"/bin/tar"];
	NSString *tar = JBBFindTool(cands);
	if (!tar.length) {
		s.ok = NO;
		s.note = @"iCloud 里只有 tar.gz，但找不到 tar 不能解包";
		return s;
	}
	NSString *out = nil;
	// 归档内部顶层就是 <name>/ 这一层，所以解到 work 的父目录即可
	NSString *parent = [work stringByDeletingLastPathComponent];
	JBBRunTool(tar, @[ @"-xzf", archive, @"-C", parent ], &out);
	NSString *extracted = [parent stringByAppendingPathComponent:name];
	if (JBBFileExists(extracted)) {
		s.dir = extracted;
		s.note = [NSString stringWithFormat:@"从 iCloud 的 %@ 解包得到", [archive lastPathComponent]];
		s.ok = YES;
		return s;
	}
	s.ok = NO;
	s.note = [NSString stringWithFormat:@"iCloud 归档解包失败：%@",
			  (out.length ? out : @"tar 无输出")];
	return s;
}

#pragma mark - 引擎

@implementation JBBRestoreEngine

+ (NSDictionary *)manifestForBackupName:(NSString *)name {
	NSString *dir = [JBBBackupEngine pathForBackupName:name];
	NSDictionary *m = JBBReadPlist([dir stringByAppendingPathComponent:@"manifest.plist"]);
	if (!m) {
		// 本地没有就试试 iCloud（iCloud 里只有归档时读不到 manifest，也不值得为读清单解包）
		NSString *idir = [JBBIcloudRoot() stringByAppendingPathComponent:name];
		m = JBBReadPlist([idir stringByAppendingPathComponent:@"manifest.plist"]);
	}
	return m ?: @{};
}

+ (NSString *)summaryForBackupName:(NSString *)name {
	NSString *dir = [JBBBackupEngine pathForBackupName:name];
	NSDictionary *m = [self manifestForBackupName:name];

	NSMutableString *s = [NSMutableString string];
	[s appendFormat:@"备份：%@\n", name];

	NSDictionary *counts = m[@"counts"];
	if ([counts isKindOfClass:[NSDictionary class]]) {
		[s appendFormat:@"已安装包 %@ 个（其中你自己装的 %@ 个）\n",
			counts[@"packagesTotal"] ?: @"?", counts[@"packagesManual"] ?: @"?"];
		[s appendFormat:@"全局配置 %@ 个 · App 沙盒配置 %@ 个（覆盖 %@ 个 App）\n",
			counts[@"prefsGlobal"] ?: @"?",
			counts[@"prefsContainer"] ?: @"?",
			counts[@"containerHosts"] ?: @"?"];
		if (counts[@"aptCacheDebs"]) {
			[s appendFormat:@"apt 缓存 deb %@ 个\n", counts[@"aptCacheDebs"]];
		}
		NSNumber *exact = counts[@"manualIsExact"];
		if ([exact isKindOfClass:[NSNumber class]] && ![exact boolValue]) {
			[s appendString:@"⚠️ 插件清单为「近似推算」（当时 apt 没有 extended_states 记录）\n"];
		}
	} else {
		[s appendString:@"（没有 manifest.plist，无法给出详细统计）\n"];
	}

	NSString *created = m[@"created"];
	if ([created isKindOfClass:[NSString class]] && created.length) {
		[s appendFormat:@"创建于 %@（%@ / iOS %@）\n", created,
			m[@"machine"] ?: @"?", m[@"ios"] ?: @"?"];
	}

	// 备份内容哪几块在
	NSMutableArray<NSString *> *has = [NSMutableArray array];
	if (JBBFileExists([dir stringByAppendingPathComponent:@"packages/packages-manual.txt"]))
		[has addObject:@"包清单"];
	if (JBBFileExists([dir stringByAppendingPathComponent:@"sources"])) [has addObject:@"apt 源"];
	if (JBBListDir([dir stringByAppendingPathComponent:@"prefs/global"]).count) [has addObject:@"全局配置"];
	if (JBBListDir([dir stringByAppendingPathComponent:@"prefs/containers"]).count) [has addObject:@"沙盒配置"];
	if (JBBListDir([dir stringByAppendingPathComponent:@"prefs/appsupport"]).count) [has addObject:@"App Support"];
	if (JBBListDir([dir stringByAppendingPathComponent:@"appcache"]).count) [has addObject:@"缓存 deb"];
	if (has.count) [s appendFormat:@"内容：%@\n", [has componentsJoinedByString:@"、"]];

	NSString *archive = [dir stringByAppendingPathExtension:@"tar.gz"];
	if (JBBFileExists(archive)) {
		[s appendFormat:@"归档：%@\n", JBBHumanSize(JBBPathSize(archive))];
	}
	if (JBBFileExists([dir stringByAppendingPathComponent:@"restore-packages.sh"])) {
		[s appendString:@"含重装脚本 restore-packages.sh\n"];
	}

	NSArray *warns = m[@"warnings"];
	if ([warns isKindOfClass:[NSArray class]] && warns.count) {
		[s appendFormat:@"备份时的提示 %lu 条（详情见备份目录里 manifest.plist）\n",
			(unsigned long)warns.count];
	}
	return s;
}

+ (NSString *)packagesScriptPathForBackupName:(NSString *)name {
	NSString *dir = [JBBBackupEngine pathForBackupName:name];
	NSString *p = [dir stringByAppendingPathComponent:@"restore-packages.sh"];
	if (JBBFileExists(p)) return p;
	NSString *idir = [JBBIcloudRoot() stringByAppendingPathComponent:name];
	NSString *ip = [idir stringByAppendingPathComponent:@"restore-packages.sh"];
	if (JBBFileExists(ip)) return ip;
	// 归档在 iCloud 里的话，让用户用解包后的路径
	JBBRSource *s = JBBRResolveSource(name);
	if (s.ok) {
		NSString *sp = [s.dir stringByAppendingPathComponent:@"restore-packages.sh"];
		if (JBBFileExists(sp)) return sp;
	}
	return nil;
}

+ (NSString *)packagesScriptCommandForBackupName:(NSString *)name {
	NSString *path = [self packagesScriptPathForBackupName:name];
	if (!path.length) path = [[JBBBackupEngine pathForBackupName:name]
							  stringByAppendingPathComponent:@"restore-packages.sh"];
	return [NSString stringWithFormat:@"su -c 'sh \"%@\"'", path];
}

+ (JBBRestoreResult *)restoreConfigsFromBackupName:(NSString *)name
										  progress:(JBBProgressBlock)progress {
	JBBRestoreResult *res = [[JBBRestoreResult alloc] init];
	NSMutableArray<NSString *> *warns = [NSMutableArray array];
	NSMutableArray<NSString *> *lines = [NSMutableArray array];

	// ---------- 0. 前置检查 ----------
	JBBRReport(progress, @"检查越狱环境…", 0.03);
	if (!JBBJBReady()) {
		res.ok = NO;
		res.title = @"没有探测到越狱环境";
		res.detail = @"还原配置必须把文件写回 /var/mobile/Library/Preferences 与各 App 沙盒，\n"
					 @"这些路径只有在【重新越狱之后】才存在。\n\n"
					 @"请先完成越狱（Sileo 能正常打开即可），再回到本页点「还原配置」。\n"
					 @"如果你还没重装插件，先跑备份里的 restore-packages.sh。";
		JBBLog(@"还原中止：%@", res.title);
		JBBRReport(progress, @"中止", 1.0);
		return res;
	}
	JBBLog(@"===== 开始还原配置：%@ =====", name);

	JBBRReport(progress, @"定位备份…", 0.07);
	JBBRSource *src = JBBRResolveSource(name);
	if (!src.ok) {
		res.ok = NO;
		res.title = @"找不到这个备份";
		res.detail = src.note;
		JBBLog(@"还原中止：%@", src.note);
		JBBRReport(progress, @"中止", 1.0);
		return res;
	}
	NSString *dir = src.dir;
	[lines addObject:[NSString stringWithFormat:@"备份来源：%@（%@）", src.note, dir]];

	NSString *prefsGlobalSrc   = [dir stringByAppendingPathComponent:@"prefs/global"];
	NSString *prefsContSrc     = [dir stringByAppendingPathComponent:@"prefs/containers"];
	NSString *appSupportSrc    = [dir stringByAppendingPathComponent:@"prefs/appsupport"];

	if (!JBBFileExists(prefsGlobalSrc) && !JBBFileExists(prefsContSrc) &&
		!JBBFileExists(appSupportSrc)) {
		res.ok = NO;
		res.title = @"这个备份里没有配置数据";
		res.detail = [NSString stringWithFormat:
			@"%@\n\n目录下既没有 prefs/global，也没有 prefs/containers、prefs/appsupport。\n"
			@"说明当初备份时没勾选配置项，或者这是个只含包清单的备份。\n"
			@"你可以用 restore-packages.sh 把插件装回来。", dir];
		JBBLog(@"还原中止：%@", res.title);
		JBBRReport(progress, @"中止", 1.0);
		return res;
	}

	// ---------- 1. 安全快照 ----------
	JBBRReport(progress, @"另存当前配置（安全快照）…", 0.12);
	NSString *safety = [JBBOutputRoot() stringByAppendingPathComponent:
						[NSString stringWithFormat:@"_restore-safety-%@", JBBTimestampString()]];
	NSString *safetyGlobal = [safety stringByAppendingPathComponent:@"global"];
	NSString *safetyCont   = [safety stringByAppendingPathComponent:@"containers"];
	NSString *safetyAppSup = [safety stringByAppendingPathComponent:@"appspport"];
	if (!JBBEnsureDir(safety)) {
		res.ok = NO;
		res.title = @"无法建立安全快照目录";
		res.detail = [NSString stringWithFormat:
			@"创建 %@ 失败。\n为了不让你在「没有退路」的情况下覆盖配置，本次还原已中止。", safety];
		JBBLog(@"还原中止：%@", res.title);
		JBBRReport(progress, @"中止", 1.0);
		return res;
	}
	res.safetyDir = safety;

	NSMutableArray<NSString *> *kept = [NSMutableArray array];

	// ---------- 2. 全局偏好 ----------
	NSUInteger globalDone = 0, globalFail = 0;
	NSString *prefDst = @"/var/mobile/Library/Preferences";
	if (JBBFileExists(prefsGlobalSrc)) {
		JBBRReport(progress, @"还原全局插件配置…", 0.30);
		if (!JBBEnsureDir(prefDst)) {
			[warns addObject:[NSString stringWithFormat:@"目标目录不可写：%@", prefDst]];
		} else {
			NSArray<NSString *> *files = JBBListDir(prefsGlobalSrc);
			NSUInteger done = 0;
			for (NSString *n in files) {
				if (![n hasSuffix:@".plist"]) continue;      // _index.txt 之类不参与还原
				done++;
				NSString *from = [prefsGlobalSrc stringByAppendingPathComponent:n];
				NSString *to   = [prefDst stringByAppendingPathComponent:n];
				JBBRSafetyKeep(to, safetyGlobal, NO, kept);
				if (JBBRCopyFile(from, to, warns)) globalDone++;
				else globalFail++;
				if ((done % 30) == 0) {
					JBBRReport(progress, [NSString stringWithFormat:@"还原全局配置…（%lu）",
										  (unsigned long)globalDone], 0.30);
				}
			}
		}
	} else {
		[warns addObject:@"备份里没有 prefs/global（当初可能没勾选全局配置）"];
	}
	res.globalRestored = globalDone;
	[lines addObject:[NSString stringWithFormat:
		@"全局配置：还原 %lu 个（失败 %lu 个）→ %@", (unsigned long)globalDone,
		(unsigned long)globalFail, prefDst]];
	JBBLog(@"全局配置：还原 %lu 个，失败 %lu 个", (unsigned long)globalDone, (unsigned long)globalFail);

	// ---------- 3. 各 App 沙盒配置（按 bundle id 重新定位容器） ----------
	NSUInteger contDone = 0, contMissing = 0, contFail = 0;
	if (JBBFileExists(prefsContSrc)) {
		JBBRReport(progress, @"重新定位 App 容器…", 0.55);

		// 先建「bundleId → 当前容器路径」的索引（只扫一次，别在循环里重复扫）
		NSMutableDictionary<NSString *, NSString *> *byBundleID = [NSMutableDictionary dictionary];
		for (NSString *container in JBBAppContainerPaths()) {
			NSString *bid = JBBContainerBundleID(container);
			if (bid.length && !byBundleID[bid]) byBundleID[bid] = container;
		}
		JBBLog(@"当前设备共有 %lu 个可识别 bundleId 的容器", (unsigned long)byBundleID.count);

		NSArray<NSString *> *hosts = JBBListDir(prefsContSrc);
		NSUInteger done = 0;
		for (NSString *entry in hosts) {
			if ([entry hasPrefix:@"_"] || [entry hasPrefix:@"."]) continue;   // _map.tsv 等
			NSString *hostDir = [prefsContSrc stringByAppendingPathComponent:entry];
			BOOL isDir = NO;
			if (![[NSFileManager defaultManager] fileExistsAtPath:hostDir isDirectory:&isDir] || !isDir) continue;
			done++;

			NSString *container = byBundleID[entry];
			if (!container.length) {
				contMissing++;
				continue;      // 这个 App 当前没装（或还没启动过、容器没生成）
			}
			NSString *dstPref = [container stringByAppendingPathComponent:@"Library/Preferences"];
			if (!JBBEnsureDir(dstPref)) {
				[warns addObject:[NSString stringWithFormat:@"容器目录不可写：%@", dstPref]];
				contFail++;
				continue;
			}
			NSString *safetyHost = [safetyCont stringByAppendingPathComponent:entry];
			for (NSString *n in JBBListDir(hostDir)) {
				if (![n hasSuffix:@".plist"]) continue;
				NSString *to = [dstPref stringByAppendingPathComponent:n];
				JBBRSafetyKeep(to, safetyHost, NO, kept);
				if (JBBRCopyFile([hostDir stringByAppendingPathComponent:n], to, warns)) contDone++;
				else contFail++;
			}
			if ((done % 5) == 0) {
				JBBRReport(progress, [NSString stringWithFormat:@"还原沙盒配置…（%lu 个 App）",
									  (unsigned long)done], 0.55);
			}
		}
	}
	res.containerRestored = contDone;
	res.containerMissing  = contMissing;
	[lines addObject:[NSString stringWithFormat:
		@"App 沙盒配置：还原 %lu 个文件（%lu 个 App 找不到容器，失败 %lu）",
		(unsigned long)contDone, (unsigned long)contMissing, (unsigned long)contFail]];
	if (contMissing) {
		[lines addObject:@"  · 找不到容器的 App 说明当前设备上还没装 / 还没打开过。"];
		[lines addObject:@"    装回来并至少启动一次，然后重新点一次「还原配置」即可。"];
	}
	JBBLog(@"沙盒配置：还原 %lu 个文件，缺容器 %lu 个，失败 %lu",
		   (unsigned long)contDone, (unsigned long)contMissing, (unsigned long)contFail);

	// ---------- 4. Application Support ----------
	NSUInteger apDone = 0, apFail = 0;
	NSString *apDstRoot = @"/var/mobile/Library/Application Support";
	if (JBBFileExists(appSupportSrc)) {
		JBBRReport(progress, @"还原 Application Support…", 0.85);
		if (!JBBEnsureDir(apDstRoot)) {
			[warns addObject:[NSString stringWithFormat:@"目标目录不可写：%@", apDstRoot]];
		} else {
			for (NSString *n in JBBListDir(appSupportSrc)) {
				if ([n hasPrefix:@"."]) continue;
				if ([n isEqualToString:@"_index.txt"]) continue;
				NSString *from = [appSupportSrc stringByAppendingPathComponent:n];
				NSString *to   = [apDstRoot stringByAppendingPathComponent:n];
				BOOL isDir = NO;
				[[NSFileManager defaultManager] fileExistsAtPath:from isDirectory:&isDir];
				JBBRSafetyKeep(to, safetyAppSup, isDir, kept);
				BOOL ok = isDir ? JBBRCopyDir(from, to, warns) : JBBRCopyFile(from, to, warns);
				if (ok) apDone++; else apFail++;
			}
		}
	}
	if (apDone || apFail) {
		[lines addObject:[NSString stringWithFormat:
			@"Application Support：还原 %lu 个条目（失败 %lu 个）", (unsigned long)apDone, (unsigned long)apFail]];
	}
	JBBLog(@"Application Support：还原 %lu 个，失败 %lu 个", (unsigned long)apDone, (unsigned long)apFail);

	// ---------- 5. 收尾报告 ----------
	JBBRReport(progress, @"写入还原记录…", 0.95);
	NSDictionary *record = @{
		@"tool": JBB_VERSION,
		@"restoredAt": JBBTimestampString(),
		@"fromBackup": name,
		@"sourceNote": src.note ?: @"",
		@"sourceDir": dir,
		@"globalRestored": @(res.globalRestored),
		@"containerRestored": @(res.containerRestored),
		@"containerMissing": @(res.containerMissing),
		@"appSupportRestored": @(apDone),
		@"currentConfigKept": kept.count ? [kept copy] : @[],
		@"warnings": warns.count ? [warns copy] : @[],
	};
	JBBWritePlist(record, [safety stringByAppendingPathComponent:@"restore-record.plist"]);

	[lines addObject:@""];
	[lines addObject:[NSString stringWithFormat:@"覆盖前的当前配置已另存到：\n%@（%lu 个文件）",
					  safety, (unsigned long)kept.count]];
	if (warns.count) {
		[lines addObject:@""];
		[lines addObject:[NSString stringWithFormat:@"提示 %lu 条：", (unsigned long)warns.count]];
		NSUInteger shown = 0;
		for (NSString *w in warns) {
			if (shown++ >= 8) { [lines addObject:@"  …（其余见日志）"]; break; }
			[lines addObject:[NSString stringWithFormat:@"  · %@", w]];
		}
	}

	res.ok = ((globalDone + contDone + apDone) > 0);
	res.title = res.ok
		? [NSString stringWithFormat:@"已还原：全局 %lu · 沙盒 %lu · AppSupport %lu",
		   (unsigned long)globalDone, (unsigned long)contDone, (unsigned long)apDone]
		: @"没有还原任何文件";
	if (!res.ok) {
		[lines addObject:@"本次没有任何文件被写入 —— 可能备份里配置为空，或所有目标都不可写。"];
	}
	[lines addObject:@""];
	[lines addObject:@"下一步：回主界面点「注销桌面」让插件重新加载配置。"];
	res.detail = [lines componentsJoinedByString:@"\n"];

	JBBLog(@"===== 还原完成：全局 %lu / 沙盒 %lu / AppSupport %lu，缺容器 %lu，安全快照 %@ =====",
		   (unsigned long)globalDone, (unsigned long)contDone, (unsigned long)apDone,
		   (unsigned long)contMissing, safety);

	JBBRReport(progress, @"完成", 1.0);
	return res;
}

@end
