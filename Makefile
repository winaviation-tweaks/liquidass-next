TARGET := iphone:clang:latest:16.6
INSTALL_TARGET_PROCESSES = backboardd
THEOS_DEVICE_IP = 127.0.0.1
FINALPACKAGE = 1
THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidGlass

LiquidGlass_FILES = Tweak.mm LGSymbolResolver.mm
LiquidGlass_CFLAGS = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions
LiquidGlass_FRAMEWORKS = Metal QuartzCore CoreFoundation
LiquidGlass_PRIVATE_FRAMEWORKS =
LiquidGlass_LDFLAGS = -lc++

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += LiquidGlassSB
include $(THEOS_MAKE_PATH)/aggregate.mk
