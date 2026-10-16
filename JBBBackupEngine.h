//
//  JBBBackupEngine.h
//

#import <Foundation/Foundation.h>

/// 备份选项（持久化在 /var/mobile/Documents/JBBackup/_appconfig.plist）
@interface JBBBackupOptions : NSObject

/// 是否连 com.apple.* 的系统偏好一起备份（默认 NO —— 系统偏好与插件无关，且体积大）
@property (nonatomic, assign) BOOL includeApplePrefs;
/// 是否备份各 App 沙盒内的插件配置（默认 YES —— 微信/抖音类插件常把配置写在这里）
@property (nonatomic, assign) BOOL includeContainerPrefs;
/// 是否备份 /var/mobile/Library/Application Support（默认 YES —— Activator 等插件把配置放这）
@property (nonatomic, assign) BOOL includeAppSupport;
/// 是否带上 apt 已缓存的 .deb（默认 YES —— 重装时可离线装回原版本）
@property (nonatomic, assign) BOOL includeAptCache;
/// 是否备份 /var/mobile/Documents 下的其它内容（默认 NO —— 可能很大）
@property (nonatomic, assign) BOOL includeMedia;

+ (instancetype)defaultOptions;
- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)optionsFromDictionary:(NSDictionary *)dict;

@end

/// 一次备份的结果
@interface JBBBackupResult : NSObject

@property (nonatomic, assign) BOOL ok;
@property (nonatomic, copy) NSString *dirPath;          ///< 备份目录（/var/mobile/Documents/JBBackup/<时间戳>）
@property (nonatomic, copy) NSString *archivePath;      ///< tar.gz 归档路径（打包失败时为 nil，目录仍完整可用）
@property (nonatomic, copy) NSString *icloudPath;       ///< iCloud Drive 里的副本路径
@property (nonatomic, assign) NSUInteger packageTotal;
@property (nonatomic, assign) NSUInteger packageManual;
@property (nonatomic, assign) BOOL manualIsExact;       ///< 手动安装清单是否来自 apt 精确记录
@property (nonatomic, assign) NSUInteger prefsGlobal;
@property (nonatomic, assign) NSUInteger prefsContainer;
@property (nonatomic, assign) NSUInteger containerHosts;
@property (nonatomic, assign) NSUInteger sourceFiles;
@property (nonatomic, assign) NSUInteger aptCacheDebs;
@property (nonatomic, assign) unsigned long long bytes;
@property (nonatomic, copy) NSString *warnings;

@end

/// 进度回调（stage 为中文阶段名，fraction 0~1；保证在主线程调用）
typedef void (^JBBProgressBlock)(NSString *stage, double fraction);

@interface JBBBackupEngine : NSObject

/// 已有备份的目录名，按时间倒序
+ (NSArray<NSString *> *)listBackupNames;
/// 备份目录名 → 绝对路径
+ (NSString *)pathForBackupName:(NSString *)name;
/// 执行备份（同步阻塞，调用方必须放到后台队列）。progress 在主线程回调。
+ (JBBBackupResult *)backupWithOptions:(JBBBackupOptions *)options
                              progress:(JBBProgressBlock)progress;

/// 把某个备份目录打包成 tar.gz，返回归档路径（失败返回 nil）
+ (NSString *)archiveBackupDirNamed:(NSString *)name;

@end
