TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PodsGrant

PodsGrant_FILES = Tweak.c Sharing_Tweak.x general.c os_log_handler.c
PodsGrant_CFLAGS = -fobjc-arc -O2 -DIS_ROOTLESS=1
PodsGrant_LIBRARIES = substrate
PodsGrant_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += podsgrantsettings

include $(THEOS_MAKE_PATH)/aggregate.mk
