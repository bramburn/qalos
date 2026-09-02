# qalos emulator (x86_64) product definition.
#
# Inherits the standard AOSP x86_64 product — same kernel, same HALs, same boot
# image — and overrides the visible product metadata. This is the minimum needed
# to ship a working AOSP build under the qalos name.

$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_x86_64.mk)
$(call inherit-product, device/qalos/qalos_emulator/device.mk)

PRODUCT_NAME := qalos_emulator
PRODUCT_DEVICE := qalos_emulator

# Branding — these end up in ro.product.* and ro.build.*
PRODUCT_BRAND := QA Lab
PRODUCT_MODEL := QA Lab Operating System
PRODUCT_MANUFACTURER := QA Lab

# Distinguish qalos builds from upstream AOSP.
BUILD_ID := QAL.$(shell date -u +%Y%m%d).001
DISPLAY_BUILD_ID := qalos-$(shell date -u +%Y%m%d)
BUILD_VERSION_TAGS := qalos
