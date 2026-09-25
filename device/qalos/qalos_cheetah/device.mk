# device.mk — qalos-specific additions layered on Google's cheetah tree.
#
# IMPORTANT: the build system does NOT auto-load device.mk (nothing in
# build/make/core references it). This file only takes effect because
# qalos_cheetah.mk inherits it explicitly — the same pattern
# device/qalos/qalos_emulator uses. The previous comment claiming it was
# "loaded after BoardConfig.mk during the build configuration phase" was
# wrong: as written, the overlay and the audit property were dead config.

# Google's cheetah device makefile (vendored under device/google/cheetah/).
# Duplicate inheritance is safe: AOSP's import-nodes dedupes
# already-imported nodes ("skipping already-imported",
# build/make/core/node_fns.mk), so forks whose aosp_cheetah.mk already
# inherits this file are unaffected, and forks that don't still get the
# device config.
$(call inherit-product, device/google/cheetah/device.mk)

# qalos-specific overlay packages (signing keys, branding, etc.).
# overlay/ is not populated yet, so only register it once it exists.
# DEVICE_PACKAGE_OVERLAYS is the AOSP-15-recommended form;
# PRODUCT_PACKAGE_OVERLAYS still works but emits a deprecation warning
# (see device/qalos/qalos_emulator/device.mk).
ifneq ($(wildcard device/qalos/qalos_cheetah/overlay),)
DEVICE_PACKAGE_OVERLAYS += device/qalos/qalos_cheetah/overlay
endif

# Audit logging is MANDATORY per legal/AGENTS.md §2.9. This property is
# the on-device switch; the event-capture side is RemoteControlService,
# injected into frameworks/base by tools/apply-qalos.sh (see
# packages/apps/RemoteControlService/).
PRODUCT_PROPERTY_OVERRIDES += \
    persist.sys.qalos.audit_logging=true
