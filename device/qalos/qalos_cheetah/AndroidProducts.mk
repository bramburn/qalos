# qalos Pixel 7 Pro (cheetah) — product definitions
#
# This product inherits the Google cheetah device tree (which must be vendored
# under device/google/cheetah/ — see that directory's README.md for how to
# populate it from a community fork) and adds qalos-specific configuration.

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/qalos_cheetah.mk

# Vanilla build
COMMON_LUNCH_CHOICES := \
    qalos_cheetah-userdebug \
    qalos_cheetah-user \
    qalos_cheetah-eng
