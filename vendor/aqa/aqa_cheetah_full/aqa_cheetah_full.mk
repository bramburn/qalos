# vendor/aqa/aqa_cheetah_full/aqa_cheetah_full.mk
#
# Full AOSP for Pixel 7 Pro (cheetah) PLUS the aqa_server automation daemon.
# Use this when a QA flow needs the complete app surface AND automation.

$(call inherit-product, device/google/pantah/aosp_cheetah.mk)
$(call inherit-product, vendor/aqa/aqa_cheetah_full/device.mk)

PRODUCT_NAME := aqa_cheetah_full
# MUST equal this directory's name — AOSP 15 resolves TARGET_DEVICE_DIR by
# searching device/*/$(TARGET_DEVICE)/BoardConfig.mk and
# vendor/*/$(TARGET_DEVICE)/BoardConfig.mk. Setting PRODUCT_DEVICE := cheetah
# would match AOSP's own device/google/pantah/cheetah/BoardConfig.mk and
# silently drop this whole layer. It also gives the product its own
# PRODUCT_OUT (out/target/product/aqa_cheetah_full), so full and slim never
# overwrite each other. Same rationale as
# device/qalos/qalos_cheetah/qalos_cheetah.mk.
PRODUCT_DEVICE := aqa_cheetah_full
PRODUCT_BRAND := AQA
PRODUCT_MODEL := Pixel 7 Pro (AQA Full)

# The automation daemon. cc_binary without `vendor: true` installs to
# /system/bin/aqa_server, matching the path in server/aqa_server.rc, and its
# `init_rc:` property installs the .rc to /system/etc/init/.
PRODUCT_PACKAGES += aqa_server

PRODUCT_PROPERTY_OVERRIDES += \
    ro.aqa.mode=full \
    ro.debuggable=1

# No BUILD_FINGERPRINT override. AOSP computes it from PRODUCT_BRAND,
# TARGET_PRODUCT, TARGET_DEVICE, TARGET_BUILD_VARIANT and BUILD_VERSION_TAGS
# (build/make/core/sysprop.mk). A hardcoded literal breaks -user/-eng builds
# and desyncs ro.product.* from the actual lunch variant. Same decision as
# device/qalos/qalos_cheetah/qalos_cheetah.mk.