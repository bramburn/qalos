# qalos Pixel 7 Pro (cheetah) â€” vanilla build
#
# Inherits the official AOSP cheetah product. In AOSP 15 the Pixel 7 Pro
# config is public and ships in the manifest: the product/board/device
# makefiles live under device/google/pantah/ (cheetah is the GS201-based
# "pantah" platform), and `repo sync` already fetches them â€” no community
# fork needed for the device tree itself. Only the proprietary blobs are
# missing (see device/google/cheetah/README.md).

# --- Kernel prebuilts: point cheetah at the 5.10 tree that is actually synced ---
#
# The public manifest at android-15.0.0_r1 ships only
# device/google/pantah-kernels/5.10 (tag 24Q3-12115410), but the release
# config asks for 6.1:
#   build/release/flag_values/trunk_staging/RELEASE_KERNEL_CHEETAH_DIR.textproto
#     string_value: "device/google/pantah-kernels/6.1/trunk-11970169"
#
# device/google/pantah/device-cheetah.mk:22-23 then does
#   TARGET_KERNEL_DIR ?= $(RELEASE_KERNEL_CHEETAH_DIR)
#   TARGET_BOARD_KERNEL_HEADERS ?= $(RELEASE_KERNEL_CHEETAH_DIR)/kernel-headers
# so the missing 6.1 tree surfaces as a ninja failure on the one target that
# needs the prebuilt image:
#   FAILED: ninja: 'device/google/pantah-kernels/6.1/trunk-11970169/Image.lz4',
#     needed by 'out/target/product/qalos_cheetah/kernel', missing and no
#     known rule to make it
#
# Override RELEASE_KERNEL_CHEETAH_DIR BEFORE the inherit so device-cheetah.mk's
# `?=` picks up the tree we actually have. The 5.10 dir contains Image.lz4,
# System.map, the vendor_kernel_boot.modules.load and the .ko modules, so it is
# a complete enough prebuilt set to build against.
# Set before the inherit, not after -- `?=` only honours a pre-set value.
_qalos_kernel_dir := $(firstword $(wildcard device/google/pantah-kernels/5.10/*))
ifneq ($(_qalos_kernel_dir),)
RELEASE_KERNEL_CHEETAH_DIR := $(_qalos_kernel_dir)
TARGET_KERNEL_DIR := $(_qalos_kernel_dir)
TARGET_BOARD_KERNEL_HEADERS := $(_qalos_kernel_dir)/kernel-headers
endif
# End kernel prebuilt override.

$(call inherit-product, device/google/pantah/aosp_cheetah.mk)
# qalos additions (overlay, audit-logging property). device.mk is NOT
# auto-loaded by the build system â€” it only takes effect because it is
# inherited here (same explicit pattern as device/qalos/qalos_emulator).
$(call inherit-product, device/qalos/qalos_cheetah/device.mk)


PRODUCT_NAME := qalos_cheetah
# PRODUCT_DEVICE MUST equal the directory name containing this
# AndroidProducts.mk. AOSP 15 discovers BoardConfig.mk by searching
# device/ and vendor/ for '*/$(TARGET_DEVICE)/BoardConfig.mk'
# (build/make/core/board_config.mk). With PRODUCT_DEVICE := cheetah the
# search matches AOSP's own device/google/pantah/cheetah/BoardConfig.mk
# and this entire qalos layer is silently ignored. TARGET_DEVICE=qalos_cheetah
# also gives the product its own
# output directory (PRODUCT_OUT := out/target/product/$(TARGET_DEVICE),
# build/make/core/envsetup.mk), so vanilla and slim never collide.
PRODUCT_DEVICE := qalos_cheetah
PRODUCT_BRAND := qalos
PRODUCT_MODEL := qalos for Pixel 7 Pro

# qalos-specific apps.
#
# Do NOT add "AuditLogger" here â€” no such module exists in the tree and an
# unknown PRODUCT_PACKAGES entry aborts the build. Audit capture is
# implemented by RemoteControlService, which tools/apply-qalos.sh injects
# into frameworks/base as a patch (it is not a PRODUCT_PACKAGES module);
# see legal/AGENTS.md Â§2.9 and packages/apps/RemoteControlService/.
PRODUCT_PACKAGES += QaLab

# Do NOT set BUILD_FINGERPRINT. AOSP computes it as
#   $(PRODUCT_BRAND)/$(TARGET_PRODUCT)/$(TARGET_DEVICE):$(PLATFORM_VERSION)/$(BUILD_ID)/$(BUILD_NUMBER_FROM_FILE):$(TARGET_BUILD_VARIANT)/$(BUILD_VERSION_TAGS)
# (build/make/core/sysprop.mk), which yields
# qalos/qalos_cheetah/qalos_cheetah:<rel>/<id>/<num>:<real-variant>/<real-tags>
# with the actual lunch variant. A hardcoded 'userdebug/test-keys'
# override breaks -user/-eng builds and ro.product.* consistency. Same
# decision as device/qalos/qalos_emulator/qalos_emulator.mk.
