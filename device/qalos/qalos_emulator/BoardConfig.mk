# Board config for the qalos x86_64 emulator build.
# Inherits everything from the AOSP generic x86_64 emulator board.

include device/generic/x86_64/BoardConfig.mk

# qalos: SELinux policy overlay.
#
# AOSP 15 enforces Treble: vendor policy (loaded from
# BOARD_VENDOR_SEPOLICY_DIRS) cannot add allow rules to coredomain
# types like system_server. So the qalos Remote Control Service
# policy needs to live in /vendor/qalos/qalos_emulator/sepolicy/
# and be wired via BOARD_VENDOR_SEPOLICY_DIRS.
#
# The vendor/ tree must also include the policy module's
# Android.bp so soong compiles it. apply-qalos.sh handles the copy.
BOARD_VENDOR_SEPOLICY_DIRS += vendor/qalos/qalos_emulator/sepolicy

# qalos-specific build-time tunables go here. Examples:
#   TARGET_KERNEL_CONFIG := qalos_defconfig
#   BOARD_KERNEL_CMDLINE += androidboot.qalos=1
