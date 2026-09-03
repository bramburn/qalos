# Board config for the qalos x86_64 emulator build.
# Inherits everything from the AOSP generic x86_64 emulator board.

include device/generic/x86_64/BoardConfig.mk

# qalos: include our device-specific SELinux policy overlay.
# The sepolicy/ directory contains the type definition, service
# context mapping, and allow rules for the Remote Control Service
# (packages/apps/RemoteControlService/). See that package's REBASE.md
# for the rebase procedure when AOSP changes its system_server policy.
#
# AOSP convention (per system/sepolicy/README): BOARD_SEPOLICY_DIRS
# is read from BoardConfig.mk, not from device.mk. Setting it in
# device.mk is silently ignored on AOSP 14+/15+ for vendor policy.
# We point at the vendor sepolicy tree (not system_ext or product)
# because the qalos service is compiled into system_server, which
# lives in the /system partition but its policy can live in /vendor
# (the policy build concatenates all BOARD_SEPOLICY_DIRS entries).
BOARD_SEPOLICY_DIRS += $(LOCAL_PATH)/sepolicy

# qalos-specific build-time tunables go here. Examples:
#   TARGET_KERNEL_CONFIG := qalos_defconfig
#   BOARD_KERNEL_CMDLINE += androidboot.qalos=1
