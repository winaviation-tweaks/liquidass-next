TARGET := iphone:clang:latest:16.6
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidGlassSB

LiquidGlassSB_FILES        = Tweak.x
LiquidGlassSB_CFLAGS       = -fobjc-arc
LiquidGlassSB_FRAMEWORKS   = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
