# vendor/aqa/aqa_cheetah_full/AndroidProducts.mk
#
# Full Pixel 7 Pro (cheetah) + aqa_server.
#
# AOSP discovers product makefiles by globbing
#   device/*/*/AndroidProducts.mk  and  vendor/*/*/AndroidProducts.mk
# (build/make/core/product_config.mk), so this file MUST stay exactly two
# levels below the partition root — hence vendor/aqa/<product>/, not
# vendor/aqa/products/<product>.mk. The same two-level rule applies to
# BoardConfig.mk discovery (vendor/*/$(TARGET_DEVICE)/BoardConfig.mk).

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/aqa_cheetah_full.mk

COMMON_LUNCH_CHOICES := \
    aqa_cheetah_full-userdebug \
    aqa_cheetah_full-user \
    aqa_cheetah_full-eng