TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = JBBackup

JBBackup_FILES = main.m \
	JBBAppDelegate.m \
	JBBRootViewController.m \
	JBBCommon.m \
	JBBZip.m \
	JBBBackupEngine.m \
	JBBRestoreEngine.m

JBBackup_CFLAGS = -fobjc-arc -Wno-unused-function
JBBackup_FRAMEWORKS = UIKit Foundation CoreGraphics UniformTypeIdentifiers

# 自带 ZIP 编解码只依赖 zlib（iOS 系统自带）
JBBackup_LDFLAGS = -lz

JBBackup_INSTALL_PATH = /Applications

# ⭐ TrollStore 会保留 ldid -S 写进签名的任意 entitlements；
#    没有这一行，IPA 版本就只是个被关在沙盒里、什么都读不到的普通 App。
#    （com.apple.private.security.no-sandbox + 全盘读写 + platform-application）
JBBackup_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
