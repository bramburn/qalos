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

# --- Kernel prebuilts, for a build without the Google driver zips -------------
#
# device/google/pantah/device-cheetah.mk:22 does
#     TARGET_KERNEL_DIR ?= $(RELEASE_KERNEL_CHEETAH_DIR)
# but RELEASE_KERNEL_CHEETAH_DIR is a release-config value that is NOT present
# in the public AOSP tree (verified: no definition in build/release/ or
# build/soong/, and no cheetah entries in
# build/release/flag_values/*/trunk_staging/). It ships with the full Google
# release, i.e. it needs the driver zips.
#
# With it empty, device/google/gs201/BoardConfig-common.mk:381 sets
# KERNEL_MODULE_DIR := $(TARGET_KERNEL_DIR), which ends up pointing at a
# 6.1 path (pantah-kernels/6.1/trunk-11970169) and line 396 then dies:
#     vendor_kernel_boot.modules.load not found or empty
# This aborts `lunch` itself, so no product can build -- stock upstream
# aosp_cheetah fails identically. It is not a qalos-layer bug.
#
# Only the 5.10 tree (Pixel 7 Pro / cheetah) is synced, and it does contain
# vendor_kernel_boot.modules.load. Point TARGET_KERNEL_DIR at it so a
# blob-less QA build can proceed. The wildcard keeps this working if the
# kernel tag is bumped; firstword keeps it single-valued.
#
# REMOVE this override once the GS101 platform blobs are in place: they provide a
# correctly matched kernel (with matching ramdisk, dtb and modules) and should
# win over this guess.
#
# NOTE (2026-08-28): the *device* driver zip for this build HAS been obtained
# and unpacked (google_devices-cheetah-ap3a.241005.015.a2). It supplies
# vendor/google_devices/cheetah/proprietary/ but contains NO gs101/ directory,
# so RELEASE_KERNEL_CHEETAH_DIR is still undefined and this override is STILL
# REQUIRED. The GS101/Tensor-G2 platform blobs are not publicly downloadable.
# See .pi/AOSP-BUILD-STATUS.md §3.8.
_qalos_510 := $(firstword $(wildcard $(TOP)/device/google/pantah-kernels/5.10/*))
ifneq ($(_qalos_510),)
TARGET_KERNEL_DIR := $(_qalos_510)
endif

# Optional so `lunch` on a tree without device sources synced still
# reaches a clear error at the product-config stage instead of here.
-include device/google/pantah/cheetah/BoardConfig.mk

# Do NOT set TARGET_BUILD_VARIANT here. The variant comes from the lunch
# combo (qalos_cheetah-userdebug / -user / -eng) and is fixed before this
# file is read; overriding it desyncs ro.build.type, default signing tags,
# and the emitted BUILD_FINGERPRINT from what lunch promised.
