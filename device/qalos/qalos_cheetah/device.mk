# device.mk — qalos-specific additions layered on AOSP's cheetah product.
#
# IMPORTANT: the build system does NOT auto-load device.mk (nothing in
# build/make/core references it). This file only takes effect because
# qalos_cheetah.mk inherits it explicitly — the same pattern
# device/qalos/qalos_emulator uses. The previous comment claiming it was
# "loaded after BoardConfig.mk during the build configuration phase" was
# wrong: as written, the overlay and the audit property were dead config.
#
# No Google device makefile is inherited here: qalos_cheetah.mk inherits
# device/google/pantah/aosp_cheetah.mk, which already inherits
# device/google/pantah/device-cheetah.mk (verified verbatim in AOSP
# 15.0.0_r1). This file is therefore ONLY qalos additions.

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
