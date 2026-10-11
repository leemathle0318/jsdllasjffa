ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = OBSBridgePrefs
OBSBridgePrefs_FILES = OBPrefs.m
OBSBridgePrefs_INSTALL_PATH = /Library/PreferenceBundles
OBSBridgePrefs_CFLAGS = -fobjc-arc
OBSBridgePrefs_FRAMEWORKS = UIKit Foundation
OBSBridgePrefs_PRIVATE_FRAMEWORKS = Preferences
include $(THEOS_MAKE_PATH)/bundle.mk
