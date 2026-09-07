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
# NOTE: PRODUCT_BRAND is the FIRST field of BUILD_FINGERPRINT (see
# build/make/core/sysprop.mk BUILD_FINGERPRINT rule), and AOSP 15's
# build/make/core/sysprop.mk:195 rejects spaces with:
#   error: BUILD_FINGERPRINT cannot contain spaces
# So PRODUCT_BRAND must be no-space. PRODUCT_MODEL goes in ro.product.model
# (no fingerprint) and can keep spaces. PRODUCT_MANUFACTURER goes in
# ro.product.manufacturer (also no fingerprint) and is left as the
# human-readable form for the boot screen.
PRODUCT_BRAND := QALab
PRODUCT_MODEL := QA Lab Operating System
PRODUCT_MANUFACTURER := QALab

# Do NOT set BUILD_ID / DISPLAY_BUILD_ID / BUILD_VERSION_TAGS here. None
# of them are in the .KATI_READONLY list in build/core/envsetup.mk
# (verified against android-15.0.0_r1: the actual readonly mechanism
# is `readonly-product-vars` in build/core/product.mk:615 which only
# covers PRODUCT_* variables). We deliberately leave the AOSP default
# BUILD_ID (set in build/core/build_id.mk) untouched so the qalos build
# id is still recognisably AOSP 15.0.0_r1 in dmesg. A qalos-specific
# build id is exposed via ro.qalos.build_id (see device.mk:25).
