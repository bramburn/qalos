# Board config for the qalos x86_64 emulator build.
# Inherits everything from the AOSP generic x86_64 emulator board.

include device/generic/x86_64/BoardConfig.mk

# qalos: SELinux policy overlay. DISABLED for v0 because `$(LOCAL_PATH)` is
# NOT defined inside BoardConfig.mk (there's no Android.mk in
# device/qalos/qalos_emulator/ to set it), so `$(LOCAL_PATH)/sepolicy`
# expands to just `/sepolicy` -- a path that doesn't exist on the build
# host but confuses the AOSP-15 soong selinux module into a panic in
# `removeSrcDirPrefix`:
#   unexpected relative path outside directory in removeSrcDirPrefix
#   filepath.Rel(/root/aosp, /): ../..
# The standard AOSP sepolicy modules (seapp_contexts_files, board_compat.map,
# service_contexts_files, keystore2_key_contexts_files, etc.) trip the panic
# during soong bootstrap, not qalos's own policy files. We need to either
# (a) put the policy under a vendor/ directory and set BOARD_VENDOR_SEPOLICY_DIRS
# properly, or (b) define LOCAL_PATH before using it. For v0 we ship
# without a SELinux overlay for the qalos service; the sepolicy/ directory
# is kept on disk for reference but is not consumed by the build. v0
# relies on permissive domains in init.rc for the Remote Control Service
# during early development; the proper policy overlay is queued for v0.1.
#
# AOSP convention (per system/sepolicy/README): BOARD_SEPOLICY_DIRS
# is read from BoardConfig.mk, not from device.mk. Setting it in
# device.mk is silently ignored on AOSP 14+/15+ for vendor policy.
# Re-enable once the policy is relocated to the vendor/ tree:
#   BOARD_VENDOR_SEPOLICY_DIRS := vendor/qalos/qalos_emulator/sepolicy
# BOARD_SEPOLICY_DIRS += $(LOCAL_PATH)/sepolicy

# qalos-specific build-time tunables go here. Examples:
#   TARGET_KERNEL_CONFIG := qalos_defconfig
#   BOARD_KERNEL_CMDLINE += androidboot.qalos=1
