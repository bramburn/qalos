# vendor/aqa/aqa_cheetah_slim/BoardConfig.mk
#
# Board config for the aqa_cheetah_slim product. See
# aqa_cheetah_full/BoardConfig.mk for why the directory name must equal
# PRODUCT_DEVICE.

-include device/google/pantah/cheetah/BoardConfig.mk

# QA testbed: permissive SELinux. See aqa_cheetah_full/BoardConfig.mk for the
# on-device verification step (GS201 is GKI; the winning cmdline may live in
# the vendor_boot bootconfig section).
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive