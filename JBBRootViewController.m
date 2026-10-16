//
//  JBBRootViewController.m
//  JBBackup —— 主界面
//
//  界面结构（分组表）：
//    0 环境概览   —— 一眼看清「现在到底能不能备份」
//    1 备份选项   —— 5 个开关，持久化到 _appconfig.plist
//    2 操作       —— 一键备份 / 还原配置 / 注销桌面
//    3 备份列表   —— 点进去看详情，可还原配置、复制重装命令
//    4 诊断       —— 查看 / 复制 / 清空日志
//
//  线程约定：备份与还原都是同步阻塞的重活，一律丢到全局队列；
//  进度回调由引擎保证在主线程执行，这里直接刷 UI 即可。
//

#import "JBBRootViewController.h"
#import "JBBCommon.h"
#import "JBBBackupEngine.h"
#import "JBBRestoreEngine.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/// 选项持久化文件
static NSString *const kJBBConfigFile = @"_appconfig.plist";

typedef NS_ENUM(NSInteger, JBBSection) {
	JBBSectionEnv = 0,
	JBBSectionOptions,
	JBBSectionActions,
	JBBSectionBackups,
	JBBSectionDiagnostics,
	JBBSectionCount,
};

typedef NS_ENUM(NSInteger, JBBActionRow) {
	JBBActionBackupNow = 0,
	JBBActionRestoreConfigs,
	JBBActionRespring,
	JBBActionCount,
};

typedef NS_ENUM(NSInteger, JBBDiagRow) {
	JBBDiagViewLog = 0,
	JBBDiagCopyLog,
	JBBDiagClearLog,
	JBBDiagCopyCommand,
	JBBDiagCount,
};

@interface JBBRootViewController () <UIDocumentPickerDelegate>

@property (nonatomic, strong) JBBBackupOptions *options;
@property (nonatomic, strong) NSArray<NSString *> *backupNames;
@property (nonatomic, strong) UIView *progressHeader;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, assign) BOOL busy;

@end

@implementation JBBRootViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
	[super viewDidLoad];

	self.title = @"越狱备份";
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.estimatedRowHeight = 96;
	self.navigationItem.rightBarButtonItem =
		[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
													  target:self
													  action:@selector(refreshTapped)];

	self.options = [JBBBackupOptions optionsFromDictionary:JBBReadPlist([self configPath])];
	[self buildProgressHeader];
	[self reloadBackups];

	JBBLog(@"主界面加载：%lu 个已有备份", (unsigned long)self.backupNames.count);
}

- (NSString *)configPath {
	return [JBBOutputRoot() stringByAppendingPathComponent:kJBBConfigFile];
}

- (void)buildProgressHeader {
	UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 56)];

	UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(0, 6, box.bounds.size.width, 20)];
	lab.text = @"就绪";
	lab.font = [UIFont systemFontOfSize:14.0];
	lab.textAlignment = NSTextAlignmentCenter;
	lab.textColor = [UIColor secondaryLabelColor];
	lab.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[box addSubview:lab];
	self.stageLabel = lab;

	UIProgressView *pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
	pv.frame = CGRectMake(0, 32, box.bounds.size.width, 4);
	pv.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[box addSubview:pv];
	self.progressView = pv;

	box.hidden = YES;
	self.progressHeader = box;
	self.tableView.tableHeaderView = box;
}

- (void)reloadBackups {
	self.backupNames = [JBBBackupEngine listBackupNames];
	[self.tableView reloadData];
}

- (void)refreshTapped {
	[self reloadBackups];
	JBBLog(@"手动刷新：环境 → %@", JBBJBRoot() ?: @"未越狱");
	[self toast:@"已刷新"];
}

#pragma mark - 忙碌态

- (void)setBusy:(BOOL)busy {
	// ⚠️ 必须写 ivar，绝不能写 self.busy = busy —— 那是在自定义 setter 里调自己，
	//    无限递归直接爆栈；clang 的 -Wunused-property-ivar 会顺带报出来。
	_busy = busy;
	self.navigationItem.rightBarButtonItem.enabled = !busy;
	self.progressHeader.hidden = !busy;
	if (busy) {
		self.progressView.progress = 0.0;
		self.stageLabel.text = @"准备中…";
		self.tableView.userInteractionEnabled = NO;
	} else {
		self.tableView.userInteractionEnabled = YES;
	}
}

- (void)applyProgress:(NSString *)stage fraction:(double)fraction {
	// 引擎保证这个 block 在主线程被调用
	if (!self.busy) [self setBusy:YES];
	self.stageLabel.text = [NSString stringWithFormat:@"%.0f%%  %@", fraction * 100.0, stage ?: @""];
	[self.progressView setProgress:(float)fraction animated:YES];
}

#pragma mark - 表格数据

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
	return JBBSectionCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
	switch (section) {
		case JBBSectionEnv:         return @"环境";
		case JBBSectionOptions:     return @"备份内容";
		case JBBSectionActions:     return @"操作";
		case JBBSectionBackups:     return self.backupNames.count
										? [NSString stringWithFormat:@"已有备份（%lu）", (unsigned long)self.backupNames.count]
										: @"已有备份";
		case JBBSectionDiagnostics: return @"诊断";
	}
	return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
	if (section == JBBSectionEnv) {
		return @"备份必须在还越狱的状态下做；还原配置必须在重新越狱之后做。";
	}
	if (section == JBBSectionOptions) {
		return @"默认配置已覆盖绝大多数插件。系统偏好（com.apple.*）与 Documents 大文件默认不备，避免体积失控。";
	}
	if (section == JBBSectionBackups) {
		return @"⚠️ /var/mobile/Documents 会被「抹掉所有内容和设置」清掉。备份完请用「导出」把 .zip 存到 iCloud Drive / 电脑。";
	}
	if (section == JBBSectionDiagnostics) {
		return @"出问题时把日志复制出来发我即可，日志已封顶不会无限增长。";
	}
	return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	switch (section) {
		case JBBSectionEnv:         return 1;
		case JBBSectionOptions:     return 5;
		case JBBSectionActions:     return JBBActionCount;
		case JBBSectionBackups:     return self.backupNames.count ? self.backupNames.count : 1;
		case JBBSectionDiagnostics: return JBBDiagCount;
	}
	return 0;
}

- (UITableViewCell *)cellWithReuseID:(NSString *)rid style:(UITableViewCellStyle)style {
	UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:rid];
	if (!cell) cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:rid];
	return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	switch (indexPath.section) {

		case JBBSectionEnv: {
			UITableViewCell *cell = [self cellWithReuseID:@"env" style:UITableViewCellStyleSubtitle];
			cell.textLabel.text = JBBJBReady() ? @"✅ 越狱环境就绪" : @"❌ 未探测到越狱环境";
			cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
			cell.textLabel.textColor = JBBJBReady() ? [UIColor labelColor] : [UIColor systemRedColor];
			cell.detailTextLabel.text = JBBEnvSummary();
			cell.detailTextLabel.numberOfLines = 0;
			cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
			cell.selectionStyle = UITableViewCellSelectionStyleNone;
			return cell;
		}

		case JBBSectionOptions: {
			UITableViewCell *cell = [self cellWithReuseID:@"opt" style:UITableViewCellStyleSubtitle];
			UISwitch *sw = (UISwitch *)cell.accessoryView;
			if (![sw isKindOfClass:[UISwitch class]]) {
				sw = [[UISwitch alloc] init];
				[sw addTarget:self action:@selector(optionSwitched:) forControlEvents:UIControlEventValueChanged];
				cell.accessoryView = sw;
			}
			sw.tag = indexPath.row;
			cell.detailTextLabel.numberOfLines = 0;
			cell.selectionStyle = UITableViewCellSelectionStyleNone;

			switch (indexPath.row) {
				case 0:
					cell.textLabel.text = @"各 App 沙盒内的插件配置";
					cell.detailTextLabel.text = @"微信/抖音类插件的配置常在这里 —— 强烈建议开启";
					sw.on = self.options.includeContainerPrefs;
					break;
				case 1:
					cell.textLabel.text = @"Application Support";
					cell.detailTextLabel.text = @"Activator 等插件的配置与数据";
					sw.on = self.options.includeAppSupport;
					break;
				case 2:
					cell.textLabel.text = @"apt 缓存里的 .deb";
					cell.detailTextLabel.text = @"带上就能离线装回原版本（占用较大，上限 800MB）";
					sw.on = self.options.includeAptCache;
					break;
				case 3:
					cell.textLabel.text = @"系统偏好 com.apple.*";
					cell.detailTextLabel.text = @"与插件无关，且体积大 —— 一般不用开";
					sw.on = self.options.includeApplePrefs;
					break;
				case 4:
					cell.textLabel.text = @"Documents 下的其它内容";
					cell.detailTextLabel.text = @"照片/文档等大文件，上限 500MB";
					sw.on = self.options.includeMedia;
					break;
				default: break;
			}
			return cell;
		}

		case JBBSectionActions: {
			UITableViewCell *cell = [self cellWithReuseID:@"act" style:UITableViewCellStyleSubtitle];
			cell.detailTextLabel.numberOfLines = 0;
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			switch (indexPath.row) {
				case JBBActionBackupNow:
					cell.textLabel.text = @"❶ 开始备份";
					cell.textLabel.textColor = [UIColor systemBlueColor];
					cell.detailTextLabel.text = @"采集插件清单 + 配置，双份写入（本地 + iCloud Drive）";
					break;
				case JBBActionRestoreConfigs:
					cell.textLabel.text = @"❷ 还原配置";
					cell.textLabel.textColor = [UIColor systemGreenColor];
					cell.detailTextLabel.text = @"重新越狱后点这里 → 从「文件」里挑备份 zip，自动写回各 App 沙盒";
					break;
				case JBBActionRespring:
					cell.textLabel.text = @"❸ 注销桌面";
					cell.textLabel.textColor = [UIColor systemOrangeColor];
					cell.detailTextLabel.text = @"让还原后的配置生效（respring）";
					break;
				default: break;
			}
			return cell;
		}

		case JBBSectionBackups: {
			if (!self.backupNames.count) {
				UITableViewCell *cell = [self cellWithReuseID:@"empty" style:UITableViewCellStyleDefault];
				cell.textLabel.text = @"还没有备份";
				cell.textLabel.textColor = [UIColor secondaryLabelColor];
				cell.selectionStyle = UITableViewCellSelectionStyleNone;
				return cell;
			}
			UITableViewCell *cell = [self cellWithReuseID:@"bk" style:UITableViewCellStyleSubtitle];
			NSString *name = self.backupNames[indexPath.row];
			NSDictionary *m = [JBBRestoreEngine manifestForBackupName:name];
			NSDictionary *counts = m[@"counts"];
			cell.textLabel.text = name;
			cell.textLabel.font = [UIFont monospacedSystemFontOfSize:14.0 weight:UIFontWeightMedium];
			NSMutableString *sub = [NSMutableString string];
			if ([counts isKindOfClass:[NSDictionary class]]) {
				[sub appendFormat:@"插件 %@ 个 · 全局配置 %@ · 沙盒 %@",
				 counts[@"packagesManual"] ?: @"?", counts[@"prefsGlobal"] ?: @"?", counts[@"prefsContainer"] ?: @"?"];
			} else {
				[sub appendString:@"（清单缺失）"];
			}
			NSString *dir = [JBBBackupEngine pathForBackupName:name];
			[sub appendFormat:@" · %@", JBBHumanSize(JBBPathSize(dir))];
			cell.detailTextLabel.text = sub;
			cell.detailTextLabel.numberOfLines = 0;
			cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
			return cell;
		}

		case JBBSectionDiagnostics: {
			UITableViewCell *cell = [self cellWithReuseID:@"diag" style:UITableViewCellStyleSubtitle];
			cell.detailTextLabel.numberOfLines = 0;
			switch (indexPath.row) {
				case JBBDiagViewLog:
					cell.textLabel.text = @"查看运行日志";
					cell.detailTextLabel.text = nil;
					cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
					break;
				case JBBDiagCopyLog:
					cell.textLabel.text = @"复制日志到剪贴板";
					cell.detailTextLabel.text = nil;
					cell.accessoryType = UITableViewCellAccessoryNone;
					break;
				case JBBDiagClearLog:
					cell.textLabel.text = @"清空日志";
					cell.textLabel.textColor = [UIColor systemRedColor];
					cell.detailTextLabel.text = nil;
					cell.accessoryType = UITableViewCellAccessoryNone;
					break;
				case JBBDiagCopyCommand:
					cell.textLabel.text = @"复制「重装插件」命令";
					cell.detailTextLabel.text = @"到 NewTerm 里先 su 到 root，再粘贴执行";
					cell.accessoryType = UITableViewCellAccessoryNone;
					break;
				default: break;
			}
			return cell;
		}
	}
	return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

#pragma mark - 交互

- (void)optionSwitched:(UISwitch *)sw {
	switch (sw.tag) {
		case 0: self.options.includeContainerPrefs = sw.on; break;
		case 1: self.options.includeAppSupport    = sw.on; break;
		case 2: self.options.includeAptCache      = sw.on; break;
		case 3: self.options.includeApplePrefs    = sw.on; break;
		case 4: self.options.includeMedia         = sw.on; break;
		default: break;
	}
	JBBWritePlist([self.options dictionaryRepresentation], [self configPath]);
	JBBLog(@"备份选项变更：%@", [self.options dictionaryRepresentation]);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];

	if (self.busy) { [self toast:@"正在忙，请等当前任务结束"]; return; }

	if (indexPath.section == JBBSectionActions) {
		switch (indexPath.row) {
			case JBBActionBackupNow:        [self startBackup];              break;
			case JBBActionRestoreConfigs:   [self pickArchiveForRestore];    break;
			case JBBActionRespring:         [self confirmRespring];          break;
			default: break;
		}
		return;
	}

	if (indexPath.section == JBBSectionBackups && self.backupNames.count) {
		[self showBackupDetail:self.backupNames[indexPath.row]];
		return;
	}

	if (indexPath.section == JBBSectionDiagnostics) {
		switch (indexPath.row) {
			case JBBDiagViewLog:      [self showLog];          break;
			case JBBDiagCopyLog:      JBBCopyToPasteboard(JBBLogTail(200 * 1024));
									  [self toast:@"日志已复制"];  break;
			case JBBDiagClearLog:     [self confirmClearLog];  break;
			case JBBDiagCopyCommand:  [self copyRestoreCommand]; break;
			default: break;
		}
	}
}

#pragma mark - 备份

- (void)startBackup {
	if (!JBBJBReady()) {
		[self alert:@"无法备份"
				 msg:@"没有探测到越狱环境（jbroot 里找不到 dpkg 数据库）。\n\n"
					  @"备份需要在越狱状态下进行 —— 请先完成越狱再打开本 App。\n"
					  @"如果你是用 TrollStore 装的本 App，在越狱环境下同样能正常备份。"];
		return;
	}

	unsigned long long need = JBBPathSize(@"/var/mobile/Library/Preferences");
	unsigned long long freeB = JBBFreeBytes(JBBOutputRoot());
	if (freeB < need + 50ULL * 1024ULL * 1024ULL) {
		[self alert:@"空间可能不够"
				 msg:[NSString stringWithFormat:@"剩余空间 %@，配置目录本身约 %@。\n建议先清理一些空间再备份。",
					  JBBHumanSize(freeB), JBBHumanSize(need)]];
	}
	[self runBackup];
}

- (void)runBackup {
	JBBBackupOptions *opt = self.options;
	JBBLog(@"用户触发备份，选项：%@", [opt dictionaryRepresentation]);
	[self setBusy:YES];

	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		JBBBackupResult *r = [JBBBackupEngine backupWithOptions:opt
													   progress:^(NSString *stage, double fraction) {
			[weakSelf applyProgress:stage fraction:fraction];
		}];
		dispatch_async(dispatch_get_main_queue(), ^{
			JBBRootViewController *self_ = weakSelf;
			if (!self_) return;
			[self_ setBusy:NO];
			[self_ reloadBackups];
			[self_ showBackupResult:r];
		});
	});
}

- (void)showBackupResult:(JBBBackupResult *)r {
	if (!r.ok) {
		[self alert:@"备份失败" msg:r.warnings.length ? r.warnings : @"未知原因，详见诊断日志。"];
		return;
	}
	NSMutableString *msg = [NSMutableString string];
	[msg appendFormat:@"备份目录：\n%@\n\n", r.dirPath];
	[msg appendFormat:@"插件清单：%lu 个（你自己装的 %lu 个%@）\n",
	 (unsigned long)r.packageTotal, (unsigned long)r.packageManual,
	 r.manualIsExact ? @"" : @"，为近似推算"];
	[msg appendFormat:@"全局配置：%lu 个文件\n", (unsigned long)r.prefsGlobal];
	[msg appendFormat:@"App 沙盒配置：%lu 个文件（覆盖 %lu 个 App）\n",
	 (unsigned long)r.prefsContainer, (unsigned long)r.containerHosts];
	[msg appendFormat:@"apt 缓存 deb：%lu 个\n", (unsigned long)r.aptCacheDebs];
	[msg appendFormat:@"总计：%@\n\n", JBBHumanSize(r.bytes)];
	[msg appendFormat:@"归档：%@\n", r.archivePath.length ? r.archivePath : @"（打包失败，目录仍可用）"];
	[msg appendFormat:@"iCloud：%@\n", r.icloudPath.length ? r.icloudPath : @"未写入"];
	if (r.warnings.length) {
		[msg appendFormat:@"\n提示：\n%@\n", r.warnings];
	}
	[msg appendString:@"\n现在就可以把右边的「导出」点掉，把 .zip 存到 iCloud Drive 或电脑。\n"
					  @"⚠️ 抹机后 /var/mobile/Documents 会被清空，存在手机上那份不算数。"];

	UIAlertController *a = [UIAlertController alertControllerWithTitle:@"备份完成"
															   message:msg
														preferredStyle:UIAlertControllerStyleAlert];
	if (r.archivePath.length) {
		__weak typeof(self) weakSelf = self;
		NSString *zip = r.archivePath;
		[a addAction:[UIAlertAction actionWithTitle:@"导出备份文件…"
											  style:UIAlertActionStyleDefault
											handler:^(UIAlertAction *x) { [weakSelf exportArchive:zip]; }]];
		[a addAction:[UIAlertAction actionWithTitle:@"打开所在文件夹"
											  style:UIAlertActionStyleDefault
											handler:^(UIAlertAction *x) { [weakSelf openContainingFolder:zip]; }]];
	}
	[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 还原

/*!
 ⭐ 主入口：直接弹系统文件选择器，让用户从「文件」里挑备份。
 
 为什么不能只靠 App 自己的备份列表：重新越狱之后 App 容器被抹了，
 列表里一条都没有 —— 而备份正躺在 iCloud Drive / 电脑 / 微信里。
 「点还原 → 让我选文件」才是重装后唯一说得通的路子。
 */
- (void)pickArchiveForRestore {
	if (!JBBJBReady()) {
		[self alert:@"现在还不能还原"
				 msg:@"还原配置需要把文件写回 /var/mobile/Library/Preferences 与各 App 沙盒，\n"
					  @"这些路径只有重新越狱之后才存在。\n\n"
					  @"请先完成越狱，再回来点「还原配置」。"];
		return;
	}

	// ⚠️ 别写 UTTypeGNUZipArchive —— 这个常量根本不存在，首轮 CI 就挂在它上面
	//    （'use of undeclared identifier'）。改成按后缀向系统问类型：
	//    拿不到就跳过，编译期不再依赖任何易变的常量名。
	NSMutableArray<UTType *> *types = [NSMutableArray array];
	if (UTTypeZIP) [types addObject:UTTypeZIP];
	for (NSString *ext in @[@"zip", @"gz", @"tgz", @"tar.gz", @"tar"]) {
		UTType *t = [UTType typeWithFilenameExtension:ext];
		if (t) [types addObject:t];
	}
	// 兜底：任何文件都能选。用户可能把备份改过名；就算选错也不怕，
	// 解包会给出明确错误，而不是把界面卡住。
	if (UTTypeData) [types addObject:UTTypeData];

	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	[self presentViewController:picker animated:YES completion:nil];
	JBBLog(@"弹出文件选择器（%lu 种可接受类型），等用户挑备份文件", (unsigned long)types.count);
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSURL *url = urls.firstObject;
	if (!url) return;
	JBBLog(@"用户选择的备份文件：%@", url.path ?: url.absoluteString);
	[self runRestoreFromPickedURL:url];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
	JBBLog(@"用户取消了文件选择");
}

- (void)runRestoreFromPickedURL:(NSURL *)url {
	// 文件可能来自 iCloud Drive / 其他 App 的容器，会带安全作用域。
	// 做法：在作用域开着的时候先拷进我们自己的目录，然后立刻还回去 ——
	// 后面的解包/还原是异步的，一直占着别人的作用域不礼貌，也容易失效。
	BOOL scoped = [url startAccessingSecurityScopedResource];
	NSString *src = url.path;
	NSString *base = src.lastPathComponent.length ? src.lastPathComponent : @"picked.zip";
	NSString *stamp = JBBTimestampString();
	NSString *tmp = [JBBOutputRoot() stringByAppendingPathComponent:
					 [NSString stringWithFormat:@"_incoming-%@-%@", stamp, base]];
	JBBEnsureDir(JBBOutputRoot());

	NSFileManager *fm = [NSFileManager defaultManager];
	[fm removeItemAtPath:tmp error:NULL];
	NSError *err = nil;
	BOOL copied = (src.length && JBBFileExists(src))
		? [fm copyItemAtPath:src toPath:tmp error:&err] : NO;
	if (scoped) [url stopAccessingSecurityScopedResource];

	if (!copied) {
		[self alert:@"读取这个文件失败"
				 msg:[NSString stringWithFormat:
			@"%@\n\n可能原因：iCloud 里那份还没下载完，或者这个文件已经被移走/改名。\n"
			@"把它先用「文件」App 存到「我的 iPhone」上再试一次。",
			err.localizedDescription ?: @"文件不存在或没有读取权限"]];
		return;
	}
	JBBLog(@"已把选中的备份拷到临时位置：%@（%@）", tmp, JBBHumanSize(JBBPathSize(tmp)));

	[self setBusy:YES];
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		JBBRestoreResult *r = [JBBRestoreEngine restoreConfigsFromArchiveAtPath:tmp
																	  progress:^(NSString *stage, double f) {
			[weakSelf applyProgress:stage fraction:f];
		}];
		[[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];   // 临时副本用完就删
		dispatch_async(dispatch_get_main_queue(), ^{
			JBBRootViewController *self_ = weakSelf;
			if (!self_) return;
			[self_ setBusy:NO];
			[self_ presentRestoreOutcome:r];
		});
	});
}

#pragma mark - 导出 / 跳转

/// 系统导出面板：让用户自己选存到哪（iCloud Drive、我的 iPhone、隔空投送、微信…）。
/// 这是 iOS 上唯一「一定管用」的导出方式，不依赖任何私有 URL scheme。
- (void)exportArchive:(NSString *)archivePath {
	if (!JBBFileExists(archivePath)) {
		[self alert:@"文件不见了" msg:[NSString stringWithFormat:
			@"%@\n\n可能已被删除。回备份列表点「重新打包 ZIP」可以再生成一个。", archivePath]];
		return;
	}
	NSURL *url = [NSURL fileURLWithPath:archivePath];
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForExportingURLs:@[url]];
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
	JBBLog(@"弹出导出面板：%@", archivePath);
}

/// 尽量跳到「文件」App 里备份所在的位置。
/// ⚠️ shareddocuments:// 不是公开 API，失败很正常 —— 所以失败时把路径复制给用户，
///    并告诉他手工怎么走（iCloud Drive → JBBackup）。
- (void)openContainingFolder:(NSString *)path {
	BOOL isDir = NO;
	NSString *dir = path;
	if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && !isDir) {
		dir = [path stringByDeletingLastPathComponent];
	}
	NSString *enc = [dir stringByAddingPercentEncodingWithAllowedCharacters:
					 [NSCharacterSet URLPathAllowedCharacterSet]];
	NSURL *url = enc.length ? [NSURL URLWithString:
							   [NSString stringWithFormat:@"shareddocuments://%@", enc]] : nil;
	UIApplication *app = [UIApplication sharedApplication];
	if (url && [app canOpenURL:url]) {
		[app openURL:url options:@{} completionHandler:nil];
		JBBLog(@"跳转到文件 App：%@", dir);
		return;
	}
	JBBCopyToPasteboard(dir);
	[self alert:@"没能自动跳转（已复制路径）"
			 msg:[NSString stringWithFormat:
		@"%@\n\n手动走法：打开「文件」App → 浏览 → iCloud Drive → JBBackup，\n"
		@"就能看到备份 zip，长按可以拷贝/分享出去。", dir]];
}

/// 还原结果统一弹窗（两个入口共用）
- (void)presentRestoreOutcome:(JBBRestoreResult *)r {
	UIAlertController *a = [UIAlertController alertControllerWithTitle:r.title
															  message:r.detail
													   preferredStyle:UIAlertControllerStyleAlert];
	if (r.ok) {
		__weak typeof(self) weakSelf = self;
		[a addAction:[UIAlertAction actionWithTitle:@"立即注销桌面"
											  style:UIAlertActionStyleDefault
											handler:^(UIAlertAction *x) { [weakSelf confirmRespring]; }]];
	}
	[a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

/// 从「App 里已有的备份」还原（备份列表里点进去用；主入口是选文件那条路）
- (void)pickBackupForRestore {
	if (!self.backupNames.count) {
		[self alert:@"没有可还原的备份" msg:@"先做一次备份吧。如果备份在 iCloud Drive 里，"
										   @"把它拷回 /var/mobile/Documents/JBBackup/ 即可在此处看到。"];
		return;
	}
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择要还原的备份"
																  message:@"将还原其中的全局配置与各 App 沙盒配置"
														   preferredStyle:UIAlertControllerStyleActionSheet];
	for (NSString *name in self.backupNames) {
		[sheet addAction:[UIAlertAction actionWithTitle:name
												 style:UIAlertActionStyleDefault
											   handler:^(UIAlertAction *a) {
			[self confirmRestore:name];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
	sheet.popoverPresentationController.sourceView = self.view;
	sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0,
															   self.view.bounds.size.height / 2.0, 1, 1);
	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRestore:(NSString *)name {
	if (!JBBJBReady()) {
		[self alert:@"现在还不能还原" msg:@"还原配置需要把文件写回 /var/mobile/Library/Preferences 与各 App 沙盒，"
									   @"这些路径只有重新越狱之后才存在。\n\n"
									   @"请先完成越狱，再回来点「还原配置」。"];
		return;
	}
	UIAlertController *c = [UIAlertController
		alertControllerWithTitle:@"确认还原配置？"
						 message:[NSString stringWithFormat:
			@"将把「%@」里的配置写回本机。\n\n"
			@"· 只会覆盖备份里存在的文件，不删除其它任何东西\n"
			@"· 覆盖前会先把当前配置另存到 _restore-safety-<时间戳>/\n"
			@"· 之后需要注销桌面才会生效", name]
				  preferredStyle:UIAlertControllerStyleAlert];
	[c addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
	[c addAction:[UIAlertAction actionWithTitle:@"开始还原" style:UIAlertActionStyleDestructive
									   handler:^(UIAlertAction *a) {
		[self runRestore:name];
	}]];
	[self presentViewController:c animated:YES completion:nil];
}

- (void)runRestore:(NSString *)name {
	JBBLog(@"用户触发还原配置：%@", name);
	[self setBusy:YES];

	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		JBBRestoreResult *r = [JBBRestoreEngine restoreConfigsFromBackupName:name
																   progress:^(NSString *stage, double fraction) {
			[weakSelf applyProgress:stage fraction:fraction];
		}];
		dispatch_async(dispatch_get_main_queue(), ^{
			JBBRootViewController *self_ = weakSelf;
			if (!self_) return;
			[self_ setBusy:NO];
			[self_ presentRestoreOutcome:r];
		});
	});
}

- (void)showBackupDetail:(NSString *)name {
	NSString *summary = [JBBRestoreEngine summaryForBackupName:name];
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:name
																  message:summary
														   preferredStyle:UIAlertControllerStyleActionSheet];

	if ([JBBRestoreEngine packagesScriptPathForBackupName:name]) {
		[sheet addAction:[UIAlertAction actionWithTitle:@"复制重装插件命令" style:UIAlertActionStyleDefault
											   handler:^(UIAlertAction *a) {
			JBBCopyToPasteboard([JBBRestoreEngine packagesScriptCommandForBackupName:name]);
			[self toast:@"命令已复制：到 NewTerm 先 su 再粘贴"];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:@"还原配置" style:UIAlertActionStyleDefault
										   handler:^(UIAlertAction *a) { [self confirmRestore:name]; }]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"复制备份目录路径" style:UIAlertActionStyleDefault
										   handler:^(UIAlertAction *a) {
		JBBCopyToPasteboard([JBBBackupEngine pathForBackupName:name]);
		[self toast:@"路径已复制"];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"重新打包 ZIP" style:UIAlertActionStyleDefault
										   handler:^(UIAlertAction *a) { [self repack:name]; }]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
	sheet.popoverPresentationController.sourceView = self.view;
	sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0,
															   self.view.bounds.size.height / 2.0, 1, 1);
	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)repack:(NSString *)name {
	[self setBusy:YES];
	__weak typeof(self) weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSString *a = [JBBBackupEngine archiveBackupDirNamed:name];
		dispatch_async(dispatch_get_main_queue(), ^{
			JBBRootViewController *self_ = weakSelf;
			if (!self_) return;
			[self_ setBusy:NO];
			if (a.length) [self_ alert:@"打包完成" msg:a];
			else          [self_ alert:@"打包失败" msg:@"写入失败（磁盘满或没权限），详见诊断日志。"];
		});
	});
}

#pragma mark - 诊断

- (void)showLog {
	NSString *tail = JBBLogTail(150 * 1024);
	UIAlertController *a = [UIAlertController alertControllerWithTitle:@"运行日志（尾部）"
															   message:tail
														preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"复制全部" style:UIAlertActionStyleDefault
									   handler:^(UIAlertAction *x) {
		JBBCopyToPasteboard(JBBLogTail(200 * 1024));
		[self toast:@"日志已复制"];
	}]];
	[a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)confirmClearLog {
	UIAlertController *c = [UIAlertController alertControllerWithTitle:@"清空日志？"
															   message:@"日志文件会被删除，不影响任何备份。"
														preferredStyle:UIAlertControllerStyleAlert];
	[c addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
	[c addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
									   handler:^(UIAlertAction *a) {
		JBBLogClear();
		JBBLog(@"日志已被用户清空");
		[self toast:@"已清空"];
	}]];
	[self presentViewController:c animated:YES completion:nil];
}

- (void)copyRestoreCommand {
	NSString *name = self.backupNames.firstObject;
	if (!name.length) {
		[self alert:@"没有备份" msg:@"先做一次备份，才会有重装命令可复制。"];
		return;
	}
	NSString *cmd = [JBBRestoreEngine packagesScriptCommandForBackupName:name];
	JBBCopyToPasteboard(cmd);
	[self alert:@"已复制（最新备份）" msg:[NSString stringWithFormat:
		@"%@\n\n用法：打开 NewTerm 3 → 先执行 su 切到 root → 粘贴执行。\n"
		@"脚本会自动探测 jbroot、补回 apt 源、apt update，然后逐个重装插件。", cmd]];
}

- (void)confirmRespring {
	UIAlertController *c = [UIAlertController alertControllerWithTitle:@"注销桌面？"
															   message:@"屏幕会黑一下再回到锁屏/桌面，这是正常的。"
														preferredStyle:UIAlertControllerStyleAlert];
	[c addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
	[c addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive
									   handler:^(UIAlertAction *a) {
		[self setBusy:YES];
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			BOOL ok = JBBRespring();
			dispatch_async(dispatch_get_main_queue(), ^{
				[self setBusy:NO];
				if (!ok) {
					[self alert:@"注销失败"
							 msg:@"没能发出 killall 命令。请用 Sileo 的「重启 SpringBoard」或手动重启设备。\n"
								  @"命令：killall -9 SpringBoard"];
				}
			});
		});
	}]];
	[self presentViewController:c animated:YES completion:nil];
}

#pragma mark - 小工具

- (void)alert:(NSString *)title msg:(NSString *)msg {
	JBBLog(@"[提示] %@：%@", title, msg);
	UIAlertController *a = [UIAlertController alertControllerWithTitle:title
															   message:msg
														preferredStyle:UIAlertControllerStyleAlert];
	[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
	[a addAction:[UIAlertAction actionWithTitle:@"复制内容" style:UIAlertActionStyleDefault
									   handler:^(UIAlertAction *x) {
		JBBCopyToPasteboard([NSString stringWithFormat:@"%@\n\n%@", title, msg]);
	}]];
	[self presentViewController:a animated:YES completion:nil];
}

- (void)toast:(NSString *)text {
	self.stageLabel.text = text;
	self.progressHeader.hidden = NO;
	self.progressView.progress = 1.0;
	__weak typeof(self) weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		JBBRootViewController *self_ = weakSelf;
		if (!self_ || self_.busy) return;
		self_.progressHeader.hidden = YES;
		self_.stageLabel.text = @"就绪";
	});
}

@end
