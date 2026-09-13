# Board config for the qalos x86_64 emulator build.
# Inherits everything from the AOSP generic x86_64 emulator board.

include device/generic/x86_64/BoardConfig.mk

# qalos: real initramfs (override goldfish's debug_ramdisk stub).
#
# `aosp_x86_64.mk` (inherited via qalos_emulator.mk) defaults
# `INITRAMFS_IMAGE` to `debug_ramdisk`, which emits a 638-byte stub
# ramdisk.img containing only empty directory skeletons + dev nodes +
# system/etc/ramdisk/build.prop. The stub has NO /init, NO init.rc, NO
# fstab, NO kernel modules — so when the qalos kernel boots it has
# nothing to load virtio_blk from and VFS panics on "Cannot open root
# device vda" (verified by T3, see emulator-boot-diagnosis.md).
#
# `initrd` is the standard AOSP 15 target built by
# system/core/rootdir/Android.mk. It produces a full initramfs with
# /init, init.rc, fstab.qalos_emulator, ueventd.rc, the default.prop,
# and the kernel modules the boot path needs. The build system
# automatically appends it to the kernel image during packaging, so
# the resulting kernel-ranchu is bootable on a stock AOSP emulator.
#
# This is the single change that turns the qalos image from
# "compiles, packaging passes, but kernel panics on /dev/vda" into
# "boots to Android on the local Windows emulator".
INITRAMFS_IMAGE := initrd

# Belt-and-suspenders: even if a parent BoardConfig sets
# BUILD_INIT_KERNEL_IMAGE := false, force the initramfs-to-kernel
# append on. The default for x86_64 emulator is true, but the
# explicit form survives future AOSP changes.
BUILD_INIT_KERNEL_IMAGE := true

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
