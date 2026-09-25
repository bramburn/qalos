# BoardConfig.mk — extends Google's cheetah BoardConfig with qalos-specific
# build options. Most board-level config comes from the vendored
# device/google/cheetah/BoardConfig.mk.
#
# This file is loaded via TARGET_DEVICE_DIR, which AOSP 15 resolves by
# searching device/ and vendor/ for
# '*/$(TARGET_DEVICE)/BoardConfig.mk' (build/make/core/board_config.mk).
# PRODUCT_DEVICE is qalos_cheetah (see qalos_cheetah.mk) precisely so the
# search finds THIS file rather than the vendored Google tree.

# Optional because the vendored tree is an intentionally empty stub until
# populated (see device/google/cheetah/README.md).
-include device/google/cheetah/BoardConfig.mk

# Do NOT set TARGET_BUILD_VARIANT here. The variant comes from the lunch
# combo (qalos_cheetah-userdebug / -user / -eng) and is fixed before this
# file is read; overriding it desyncs ro.build.type, default signing tags,
# and the emitted BUILD_FINGERPRINT from what lunch promised.
