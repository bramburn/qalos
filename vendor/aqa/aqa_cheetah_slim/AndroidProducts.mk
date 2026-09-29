# vendor/aqa/aqa_cheetah_slim/AndroidProducts.mk
#
# Slim Pixel 7 Pro (cheetah) + aqa_server.
# Two levels below the partition root — see aqa_cheetah_full/AndroidProducts.mk.

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/aqa_cheetah_slim.mk

COMMON_LUNCH_CHOICES := \
    aqa_cheetah_slim-userdebug \
    aqa_cheetah_slim-user \
    aqa_cheetah_slim-eng