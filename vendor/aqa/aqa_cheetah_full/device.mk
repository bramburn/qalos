# vendor/aqa/aqa_cheetah_full/device.mk
#
# Layered on AOSP's cheetah product. NOT auto-loaded — aqa_cheetah_full.mk
# inherits it explicitly (same pattern as device/qalos/qalos_cheetah).
#
# No Google makefile is inherited here: aqa_cheetah_full.mk inherits
# device/google/pantah/aosp_cheetah.mk, which already inherits
# device/google/pantah/device-cheetah.mk.

# aqa_server runs as root (see server/aqa_server.rc), so it can open
# /dev/uinput regardless of the ueventd node mode. No ueventd rule is
# installed — writing one to $(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc would
# clobber the device's own ueventd.rc (duplicate PRODUCT_COPY_FILES
# destination = build failure, or silent loss of every pantah device node
# rule if it won). Only revisit if the daemon is ever moved off root.