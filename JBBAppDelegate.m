//
//  JBBAppDelegate.m
//

#import "JBBAppDelegate.h"
#import "JBBRootViewController.h"
#import "JBBCommon.h"

@implementation JBBAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	// ⚠️ 必须在任何磁盘操作之前立一个日志：排查问题时，用户把这份日志发回来就够了。
	JBBLog(@"========== JBBackup %@ 启动（jbroot=%@）==========",
	       JBB_VERSION, JBBJBRoot() ?: @"未探测到");

	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	JBBRootViewController *root = [[JBBRootViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
	self.window.rootViewController = nav;
	[self.window makeKeyAndVisible];

	JBBLog(@"界面已就绪：%@", NSStringFromClass([root class]));
	return YES;
}

@end
