ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = posterforged
posterforged_FILES = Daemon/main.m Shared/PFShared.m Daemon/PFPosterBuilder.m Daemon/PFTendiesArchive.m Daemon/PFMemory.m
posterforged_CFLAGS = -fobjc-arc
posterforged_FRAMEWORKS = Foundation CoreFoundation UIKit AVFoundation CoreImage CoreGraphics
posterforged_LIBRARIES = z
posterforged_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/Entitlements.plist
posterforged_INSTALL_PATH = /usr/libexec
include $(THEOS_MAKE_PATH)/tool.mk

SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	chmod 0755 $(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst $(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm
	install -m 0755 $(THEOS_PROJECT_DIR)/Tools/diagnose-service.sh $(THEOS_STAGING_DIR)/usr/libexec/posterforge-diagnose-service

after-install::
	install.exec "launchctl kickstart -k system/com.posterforge.daemon || true"
