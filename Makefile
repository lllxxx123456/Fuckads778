INSTALL_TARGET_PROCESSES = AdBlockPro
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AdBlockPro

AdBlockPro_FILES = Tweak.x AdBlockPanel.mm
AdBlockPro_CFLAGS = -fobjc-arc
AdBlockPro_FRAMEWORKS = UIKit Foundation StoreKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
