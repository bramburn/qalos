# qalos emulator device-level product additions.
# Add qalos-specific packages, properties, and init hooks here.

# Inherit the AOSP x86_64 emulator-specific device config (CPU_ABI, kernel cmdline,
# ramdisk layout, etc.). This is what makes the build a working AVD image rather
# than a generic x86_64 build.
$(call inherit-product, device/generic/x86_64/device.mk)

# qalos apps to include in every qalos emulator build.
PRODUCT_PACKAGES += \
    QaLab

# Show the qalos build id on the AVD's boot screen.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.qalos.build_id=$(BUILD_ID) \
    ro.qalos.display_build_id=$(DISPLAY_BUILD_ID)

# qalos: include our device-specific SELinux policy overlay.
# The sepolicy/ directory contains the type definition, service
# context mapping, and allow rules for the Remote Control Service
# (packages/apps/RemoteControlService/). See that package's REBASE.md
# for the rebase procedure when AOSP changes its system_server policy.
BOARD_SEPOLICY_DIRS += $(LOCAL_PATH)/sepolicy
