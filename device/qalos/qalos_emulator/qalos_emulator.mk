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
# NOTE: PRODUCT_MANUFACTURER cannot contain spaces -- it is the first
# component of BUILD_FINGERPRINT, and AOSP 15's build/make/core/sysprop.mk:195
# rejects spaces with: "BUILD_FINGERPRINT cannot contain spaces". Use "QALab"
# (no space) for the manufacturer; brand and model can keep spaces.
PRODUCT_BRAND := QA Lab
PRODUCT_MODEL := QA Lab Operating System
PRODUCT_MANUFACTURER := QALab

# Do NOT set BUILD_ID / DISPLAY_BUILD_ID / BUILD_VERSION_TAGS here. In AOSP 15
# all three are declared readonly in build/make/core/envsetup.mk (around
# line 351 inside the product_config include chain). Trying to assign to
# them at the product-config layer (after envsetup has loaded) fails with
# `error: cannot assign to readonly variable: BUILD_ID`. The default
# BUILD_ID from the AOSP tag (android-15.0.0_r1) is fine; if we want a
# qalos-specific build id visible in `getprop ro.build.id`, override it
# via PRODUCT_PROPERTY_OVERRIDES in device.mk (see ro.qalos.build_id below).
