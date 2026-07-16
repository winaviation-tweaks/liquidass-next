TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidGlassSB

LiquidGlassSB_FILES        = Tweak.x
LiquidGlassSB_CFLAGS       = -fobjc-arc
LiquidGlassSB_FRAMEWORKS   = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
