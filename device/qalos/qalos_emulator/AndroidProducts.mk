# Registers the qalos products defined in this directory with the AOSP build system.
# `lunch` reads this file to populate its target list.

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/qalos_emulator.mk

COMMON_LUNCH_CHOICES := \
    qalos_emulator-userdebug \
    qalos_emulator-eng \
    qalos_emulator-user
