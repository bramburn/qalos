# qalos Pixel 7 Pro (cheetah) — product definitions
#
# Inherits the AOSP-public cheetah product, which `repo sync` already provides
# at device/google/pantah/ (cheetah is the GS201 "pantah" platform). No
# community fork is needed for the device tree; only the proprietary blobs are
# missing — see device/google/cheetah/README.md for those.
#
# MUST stay exactly two levels below device/ — AOSP discovers product
# makefiles by globbing device/*/*/AndroidProducts.mk
# (build/make/core/product_config.mk), and BoardConfig.mk by globbing
# device/*/$(TARGET_DEVICE)/BoardConfig.mk.

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/qalos_cheetah.mk

# Build variants
COMMON_LUNCH_CHOICES := \
    qalos_cheetah-userdebug \
    qalos_cheetah-user \
    qalos_cheetah-eng
