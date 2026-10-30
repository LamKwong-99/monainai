TARGET := iphone:clang:latest:13.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = podsgrantadaptivetransparency

podsgrantadaptivetransparency_FILES = Tweak.x
podsgrantadaptivetransparency_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
