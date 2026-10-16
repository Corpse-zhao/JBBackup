//
//  JBBRestoreEngine.h
//

#import <Foundation/Foundation.h>
#import "JBBBackupEngine.h"

/// 一次「还原配置」的结果
@interface JBBRestoreResult : NSObject

@property (nonatomic, assign) BOOL ok;
@property (nonatomic, copy) NSString *title;             ///< 一句话结论
@property (nonatomic, copy) NSString *detail;            ///< 详细报告（多行）
@property (nonatomic, copy) NSString *safetyDir;         ///< 还原前另存的现状目录
@property (nonatomic, assign) NSUInteger globalRestored;
@property (nonatomic, assign) NSUInteger containerRestored;
@property (nonatomic, assign) NSUInteger containerMissing;

@end

@interface JBBRestoreEngine : NSObject

/// 备份摘要（给列表/详情页展示，多行）
+ (NSString *)summaryForBackupName:(NSString *)name;
/// 备份的 manifest.plist 内容（没有则返回空字典）
+ (NSDictionary *)manifestForBackupName:(NSString *)name;
/// 是否需要先用 root 装包（= 是否生成了 restore-packages.sh）
+ (NSString *)packagesScriptPathForBackupName:(NSString *)name;
/// 给用户直接复制执行的命令
+ (NSString *)packagesScriptCommandForBackupName:(NSString *)name;

/// 还原配置：全局偏好 + 各 App 沙盒内的插件配置 + Application Support。
/// ⚠️ 只覆盖备份里「有的」那些文件；覆盖前先把现状另存到 _restore-safety-<时间戳>/。
/// 同步阻塞，调用方必须放后台队列；progress 在主线程回调。
+ (JBBRestoreResult *)restoreConfigsFromBackupName:(NSString *)name
										  progress:(JBBProgressBlock)progress;

/// ⭐ 主入口：从用户自己选的备份文件（.zip / .tar.gz）还原。
/// 内部会先解到临时目录再走上面同一条还原逻辑，所以两条路的行为完全一致。
/// 用途：重新越狱后 App 是空白的（没有任何「已有备份」记录），
///       用户直接去「文件」里挑当初导出的那个 zip 就行。
+ (JBBRestoreResult *)restoreConfigsFromArchiveAtPath:(NSString *)archivePath
											 progress:(JBBProgressBlock)progress;

@end
