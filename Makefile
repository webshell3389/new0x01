TARGET := iphone:clang:latest:13.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = coruna_hook
coruna_hook_FILES = Stage2Core.m
coruna_hook_FRAMEWORKS = Foundation CFNetwork
coruna_hook_CFLAGS = -fno-objc-arc -Wno-deprecated-declarations
coruna_hook_INSTALL_PATH = /usr/lib
coruna_hook_LINKAGE_TYPE = dynamic

include $(THEOS_MAKE_PATH)/library.mk