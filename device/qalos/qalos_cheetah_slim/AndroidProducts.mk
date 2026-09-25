# qalos Pixel 7 Pro (cheetah) — slim variant
#
# Strips ~25 packages (Launcher3, SystemUI, Music, Gallery, etc.) and keeps
# only the essentials: Camera2, Dialer, TeleService, MmsService, messaging,
# webview, Settings, plus the framework. ~3-3.5 GB system image, ~30% faster
# build than stock full build.
#
# Build with: lunch qalos_cheetah_slim-userdebug

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/qalos_cheetah_slim.mk

COMMON_LUNCH_CHOICES := \
    qalos_cheetah_slim-userdebug \
    qalos_cheetah_slim-user \
    qalos_cheetah_slim-eng
