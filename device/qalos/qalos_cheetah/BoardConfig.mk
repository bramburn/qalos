# BoardConfig.mk — extends AOSP's public cheetah BoardConfig with
# qalos-specific build options. All board-level config (gs201 common,
# kernel cmdline, sepolicy, wifi) comes from the AOSP pantah tree that
# `repo sync` already provides at device/google/pantah/.
#
# This file is loaded via TARGET_DEVICE_DIR, which AOSP 15 resolves by
# searching device/ and vendor/ for
# '*/$(TARGET_DEVICE)/BoardConfig.mk' (build/make/core/board_config.mk).
# PRODUCT_DEVICE is qalos_cheetah (see qalos_cheetah.mk) precisely so the
# search finds THIS file rather than AOSP's own
# device/google/pantah/cheetah/BoardConfig.mk (which would silently
# bypass the whole qalos layer).

# Optional so `lunch` on a tree without device sources synced still
# reaches a clear error at the product-config stage instead of here.
-include device/google/pantah/cheetah/BoardConfig.mk

# Do NOT set TARGET_BUILD_VARIANT here. The variant comes from the lunch
# combo (qalos_cheetah-userdebug / -user / -eng) and is fixed before this
# file is read; overriding it desyncs ro.build.type, default signing tags,
# and the emitted BUILD_FINGERPRINT from what lunch promised.
