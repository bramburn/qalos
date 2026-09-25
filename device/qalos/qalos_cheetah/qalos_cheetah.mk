# qalos Pixel 7 Pro (cheetah) — vanilla build
#
# Inherits from Google's cheetah device tree (vendored under
# device/google/cheetah/ — see that directory's README.md for how to
# populate it from a community fork) and layers qalos branding, packages,
# and QA-lab configuration on top.

$(call inherit-product, device/google/cheetah/aosp_cheetah.mk)
# qalos additions (overlay, audit-logging property). device.mk is NOT
# auto-loaded by the build system — it only takes effect because it is
# inherited here (same explicit pattern as device/qalos/qalos_emulator).
$(call inherit-product, device/qalos/qalos_cheetah/device.mk)

PRODUCT_NAME := qalos_cheetah
# PRODUCT_DEVICE MUST equal the directory name containing this
# AndroidProducts.mk. AOSP 15 discovers BoardConfig.mk by searching
# device/ and vendor/ for '*/$(TARGET_DEVICE)/BoardConfig.mk'
# (build/make/core/board_config.mk). With PRODUCT_DEVICE := cheetah the
# search matches the vendored device/google/cheetah/BoardConfig.mk and
# this entire qalos layer is silently ignored; before the tree is
# populated, lunch fails with "No config file found for TARGET_DEVICE
# cheetah". TARGET_DEVICE=qalos_cheetah also gives the product its own
# output directory (PRODUCT_OUT := out/target/product/$(TARGET_DEVICE),
# build/make/core/envsetup.mk), so vanilla and slim never collide.
PRODUCT_DEVICE := qalos_cheetah
PRODUCT_BRAND := qalos
PRODUCT_MODEL := qalos for Pixel 7 Pro

# qalos-specific apps.
#
# Do NOT add "AuditLogger" here — no such module exists in the tree and an
# unknown PRODUCT_PACKAGES entry aborts the build. Audit capture is
# implemented by RemoteControlService, which tools/apply-qalos.sh injects
# into frameworks/base as a patch (it is not a PRODUCT_PACKAGES module);
# see legal/AGENTS.md §2.9 and packages/apps/RemoteControlService/.
PRODUCT_PACKAGES += QaLab

# Do NOT set BUILD_FINGERPRINT. AOSP computes it as
#   $(PRODUCT_BRAND)/$(TARGET_PRODUCT)/$(TARGET_DEVICE):$(PLATFORM_VERSION)/$(BUILD_ID)/$(BUILD_NUMBER_FROM_FILE):$(TARGET_BUILD_VARIANT)/$(BUILD_VERSION_TAGS)
# (build/make/core/sysprop.mk), which yields
# qalos/qalos_cheetah/qalos_cheetah:<rel>/<id>/<num>:<real-variant>/<real-tags>
# with the actual lunch variant. A hardcoded 'userdebug/test-keys'
# override breaks -user/-eng builds and ro.product.* consistency. Same
# decision as device/qalos/qalos_emulator/qalos_emulator.mk.
