# vendor/aqa/aqa_cheetah_slim/device.mk
#
# Layered on AOSP's cheetah product. NOT auto-loaded — aqa_cheetah_slim.mk
# inherits it explicitly.
#
# No ueventd rule is installed: aqa_server runs as root and can open
# /dev/uinput regardless of the node mode. Copying a fragment to
# $(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc would clobber pantah's own
# ueventd.rc. See aqa_cheetah_full/device.mk for the full rationale.