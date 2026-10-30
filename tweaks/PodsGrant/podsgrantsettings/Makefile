TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = podsgrantsettings

podsgrantsettings_FILES = ../general.c PGSRootListController.m PGSProductIDMappingController.m PGSProductIDEditingViewController.m PGSSelectTargetProductIDViewController.m PGSCreditsViewController.m
podsgrantsettings_FRAMEWORKS = UIKit Foundation
podsgrantsettings_INSTALL_PATH = /Library/PreferenceBundles
podsgrantsettings_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
