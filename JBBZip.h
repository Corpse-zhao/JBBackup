//
//  JBBZip.h
//  JBBackup —— 自带 ZIP 打包 / 解包
//
//  为什么要自己写：
//   1. iOS SDK 里**没有**可用的 zip 解包 API（NSFileManager 不支持），
//      引第三方库又会把 CI 和体积搞复杂。
//   2. 原来打包是 spawn 外部 tar 二进制 —— 不同越狱环境 tar 的位置/参数不一致，
//      而且解包侧根本没有可用的 tar。自写 ZIP 后两端一致、零外部依赖。
//   3. 只依赖 zlib（iOS 自带），流式读写，不会把几百 MB 的备份塞进内存。
//
//  安全：解包时严格防 Zip Slip（条目名里的 ../ 或绝对路径一律拒绝），
//        并且落盘前再次确认最终路径没跑出目标目录。
//

#import <Foundation/Foundation.h>

@interface JBBZip : NSObject

/// 把目录打包成 zip。zip 内部路径为 "<目录名>/<相对路径>"，
/// 所以解包时指定「其父目录」即可还原出同名目录。
/// @return 写入的字节数；失败返回 0 并在 err 里给原因
+ (unsigned long long)createZipAtPath:(NSString *)zipPath
						fromDirectory:(NSString *)dir
								error:(NSString **)err;

/// 解包 zip 到目录（目标目录会自动创建）
/// @return 解出的文件数；失败返回 0
+ (NSUInteger)extractZipAtPath:(NSString *)zipPath
				   toDirectory:(NSString *)dir
						 error:(NSString **)err;

/// 解包 gzip 包裹的 tar（兼容 v0.1.0 生成的 .tar.gz 备份）
+ (NSUInteger)extractTarGzAtPath:(NSString *)gzPath
					 toDirectory:(NSString *)dir
						   error:(NSString **)err;

/// 按扩展名分派到上面两个之一（支持 .zip / .tar.gz / .tgz）
+ (NSUInteger)extractArchiveAtPath:(NSString *)archivePath
					   toDirectory:(NSString *)dir
							 error:(NSString **)err;

/// 这个后缀是不是我们能解的
+ (BOOL)isSupportedArchive:(NSString *)path;

@end
