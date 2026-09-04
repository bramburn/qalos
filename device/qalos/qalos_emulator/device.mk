# qalos emulator device-level product additions.
# Add qalos-specific packages, properties, and init hooks here.
#
# Note: the x86_64 emulator product config (CPU_ABI, kernel cmdline,
# ramdisk layout, etc.) is inherited via `qalos_emulator.mk` →
# `aosp_x86_64.mk` already, so we do not add another
# `$(call inherit-product, ...)` here. AOSP's `device/generic/x86_64/`
# tree in android-15.0.0_r1 has no `device.mk` (it carries only
# `AndroidProducts.mk`, `BoardConfig.mk`, `METADATA`,
# `mini_x86_64.mk`), so any such inherit would abort the build with
# `error: device/generic/x86_64/device.mk does not exist.`

# qalos apps to include in every qalos emulator build.
PRODUCT_PACKAGES += \
    QaLab

# Show the qalos build id on the AVD's boot screen.
# `PRODUCT_PROPERTY_OVERRIDES` is technically deprecated in favour of
# the partition-specific `PRODUCT_<PARTITION>_PROPERTIES` lists
# (see `core/product.mk` TODO(b/117892318)). For v0 we keep the
# deprecated form because the system-visible build-id properties are
# exactly what the AOSP compat layer still wires correctly; switching
# to `PRODUCT_SYSTEM_PROPERTIES` is a drive-by for v1.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.qalos.build_id=$(BUILD_ID) \
    ro.qalos.display_build_id=$(DISPLAY_BUILD_ID)

# Note: the qalos SELinux policy overlay is wired via BoardConfig.mk
# (not here). AOSP's sepolicy build reads BOARD_SEPOLICY_DIRS from
# BoardConfig.mk; setting it in device.mk is silently ignored on
# modern AOSP. See BoardConfig.mk in this directory.
