//
//  JBBCommon.h
//  JBBackup —— 公共基础设施：环境探测 / 路径 / 文件 / 日志 / 工具调用
//
//  ⚠️ 所有 C 库头文件集中在这里 import：本工程每个 .m 都会 import 本头文件，
//     这样就不会出现「某个 .m 用了 dlsym/posix_spawn 却没 import 对应头」的
//     编译级联报错（历史上踩过：一个漏 import 会报 4 条看着毫不相干的错）。
//

#import <Foundation/Foundation.h>

// ⚠️ UIKit 只在 iOS 宿主存在。
//    CI 里有一份 macOS 上跑的「打包 → 解包 → 内容比对」往返自测
//    （tests/ziptest.m），它要复用 JBBCommon + JBBZip；用 __has_include
//    兜住之后同一份源码两个平台都能编，不必维护一份假的 UIKit 头。
//    唯一受影响的调用点是 JBBCopyToPasteboard（下面已用同一个宏包住）。
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#define JBB_HAS_UIKIT 1
#endif

#import <spawn.h>
#import <sys/wait.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <unistd.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <stdio.h>
#import <time.h>
#import <dispatch/dispatch.h>

/// 版本号 —— 全工程唯一来源。任何要展示/写日志的版本号都必须从这里取。
#define JBB_VERSION @"0.2.0"

#pragma mark - 日志

/// 日志文件路径（/var/mobile/Documents/JBBackup/_jbbackup.log），取不到时返回 nil
NSString *JBBLogPath(void);
/// 写一行日志（同时输出到 NSLog 与日志文件；文件超过 512KB 会整份重写，不会无限膨胀）
void JBBLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
/// 取最近一段日志文本（给界面展示 / 复制用）
NSString *JBBLogTail(NSUInteger maxChars);
/// 清空日志（内存缓冲与文件一起清）
void JBBLogClear(void);

#pragma mark - 越狱环境

/// jbroot 绝对路径；探测不到时返回 nil（探测结果会缓存）
NSString *JBBJBRoot(void);
/// dpkg 数据库是否可读（= 备份功能是否可用）
BOOL JBBJBReady(void);
/// 人类可读的环境摘要，用于界面与日志
NSString *JBBEnvSummary(void);

#pragma mark - 路径

NSString *JBBMobileDocumentsDir(void);   ///< /var/mobile/Documents
NSString *JBBOutputRoot(void);           ///< /var/mobile/Documents/JBBackup
NSString *JBBIcloudRoot(void);           ///< iCloud Drive 下的 JBBackup 目录
/// 递归创建目录，返回是否成功
BOOL JBBEnsureDir(NSString *path);
/// 目标目录当前是否可写（真的写一个探针文件试，不是猜）
BOOL JBBPathWritable(NSString *path);

#pragma mark - 文件

BOOL JBBFileExists(NSString *path);
NSString *JBBReadText(NSString *path);
BOOL JBBWriteText(NSString *text, NSString *path);
BOOL JBBWriteData(NSData *data, NSString *path);
NSDictionary *JBBReadPlist(NSString *path);
BOOL JBBWritePlist(NSDictionary *dict, NSString *path);
/// 递归统计目录/文件大小（字节）；不存在返回 0
unsigned long long JBBPathSize(NSString *path);
/// 指定路径所在卷的可用空间（字节）
unsigned long long JBBFreeBytes(NSString *path);
/// 列出目录下的条目名（不含 . / ..），失败返回空数组
NSArray<NSString *> *JBBListDir(NSString *dir);

#pragma mark - 已安装包

/// 已安装包（status 为 install ok installed），元素 = {name, version, section, origin, maintainer}
NSArray<NSDictionary *> *JBBInstalledPackages(void);
/// apt 标记为「手动安装」且确实处于已安装状态的包名（= 用户自己装的插件，最佳代理指标）
NSArray<NSString *> *JBBManualPackageNames(void);
/// apt 源文件路径列表（sources.list + sources.list.d/*.list）
NSArray<NSString *> *JBBSourceFilePaths(void);

#pragma mark - App 容器

/// 读容器根目录下的 .com.apple.mobile_container_manager.metadata.plist，返回 bundle id；失败返回 nil
NSString *JBBContainerBundleID(NSString *containerPath);
/// /var/mobile/Containers/Data/Application 下所有容器路径
NSArray<NSString *> *JBBAppContainerPaths(void);

#pragma mark - 工具调用

/// 按候选路径列表找一个可执行的二进制，返回第一个可执行的
NSString *JBBFindTool(NSArray<NSString *> *candidates);
/// spawn 一个二进制并捕获 stdout+stderr；outText 可为 NULL
BOOL JBBRunTool(NSString *tool, NSArray<NSString *> *args, NSString **outText);

#pragma mark - 杂项

NSString *JBBHumanSize(unsigned long long bytes);
NSString *JBBTimestampString(void);
/// 注销桌面（respring）。返回是否成功发出命令；失败时调用方应提示用户手动注销。
BOOL JBBRespring(void);
/// 复制文本到剪贴板
void JBBCopyToPasteboard(NSString *text);
