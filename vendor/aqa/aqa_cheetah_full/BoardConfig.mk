# vendor/aqa/aqa_cheetah_full/BoardConfig.mk
#
# Board config for the aqa_cheetah_full product. Loaded via TARGET_DEVICE_DIR:
# AOSP 15 resolves it by searching
#   device/*/$(TARGET_DEVICE)/BoardConfig.mk
#   vendor/*/$(TARGET_DEVICE)/BoardConfig.mk
# (build/make/core/board_config.mk). PRODUCT_DEVICE is aqa_cheetah_full so
# the search finds THIS file — the directory name and PRODUCT_DEVICE must
# match, or the whole aqa board layer is silently skipped and AOSP's own
# device/google/pantah/cheetah/BoardConfig.mk wins instead.

# Real board config (GS201 / pantah platform). -include (not include) so a
# tree without device sources synced still reaches a clear product-config
# error rather than dying here.
-include device/google/pantah/cheetah/BoardConfig.mk

# QA testbed: permissive SELinux so the daemon can touch /dev/uinput and
# shell out without denials. Appended AFTER the -include so it extends
# pantah's cmdline rather than replacing it.
#
# VERIFY ON DEVICE: `adb shell cat /proc/cmdline` must contain
# androidboot.selinux=permissive. GS201 is a GKI device and the authoritative
# cmdline can come from the vendor_boot bootconfig section instead of the
# boot image header. If the flag does not take, add it to BOARD_BOOTCONFIG
# in this file — do NOT assume the boot image cmdline is the one that wins.
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive