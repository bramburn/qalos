# qalos emulator device-level product additions.
# Add qalos-specific packages, properties, and init hooks here.
#
# Note: the x86_64 emulator product config (CPU_ABI, kernel cmdline,
# ramdisk layout, etc.) is inherited via `qalos_emulator.mk` →
# `aosp_x86_64.mk` already, so we do not add another
# `$(call inherit-product, ...)` here. AOSP's `device/generic/x86_64/`
# tree in android-15.0.0_r1 has no `device.mk` (it carries only
# `AndroidProducts.mk`, `BoardConfig.mk`, `METADATA`,
# `mini_x86_64.mk`), so any such inherit would abort the build with
# `error: device/generic/x86_64/device.mk does not exist.`

# qalos apps to include in every qalos emulator build.
PRODUCT_PACKAGES += \
    QaLab

# ---------------------------------------------------------------------------
# Tier 1 strip — drop AOSP stock apps and OEM cruft the QA test APK does
# not exercise. See device/qalos/qalos_emulator/AGENTS.md ("Strip policy")
# for the keep/drop/conditional lists and the rationale for each name.
#
# `$(filter-out ...)` is a no-op for any name that is not currently in
# $(PRODUCT_PACKAGES), so defensive entries (e.g. `Browser2` which is
# not in aosp_x86_64) cost nothing at build time. QaLab itself is added
# above and is NOT in the filter list, so it survives.
#
# FUTURE-PRODUCT WARNING: this filter list is a no-op on `aosp_x86_64`
# (the only product that ships today) for the entries that are not in
# that product — but several of them ARE in `handheld.mk` and `full.mk`
# (e.g. `Gallery2` declares a custom
# `com.android.gallery3d.permission.GALLERY_PROVIDER` permission that
# becomes orphan if the package is dropped in a product that ships it).
# Do NOT copy this `device.mk` into a new product without auditing
# each entry's permission surface against that product's AOSP base.
# See the AGENTS.md "v1.1 — pending Aliyun access (deferred)" section
# for the build verification recipe; the per-entry "no-op on
# aosp_x86_64; do not promote to a product that ships the package"
# footnote belongs here for every defensive entry. Tier 2 will move
# the defensive entries into a separate include file that a future
# phone product can choose not to include.
#
# References (AOSP 15.0.0_r1):
#   build/target/product/generic_system.mk
#   build/target/product/handheld_system_ext.mk
#   build/target/product/aosp_product.mk
# ---------------------------------------------------------------------------
PRODUCT_PACKAGES := $(filter-out \
    LiveWallpapersPicker \
    PartnerBookmarksProvider \
    Stk \
    Tag \
    AccessibilityMenu \
    Provision \
    WallpaperCropper \
    Calendar \
    Contacts \
    DeskClock \
    Email \
    Gallery2 \
    Music \
    Browser2 \
    Calculator \
    QuickSearchBox \
    PrintSpooler \
    PrintRecommendationService \
    BackupRestoreConfirmation \
    SmartClipService \
    TextClassifierService, \
    $(PRODUCT_PACKAGES))

# ---------------------------------------------------------------------------
# Framework resource overlay. The overlay directory mirrors the upstream
# `frameworks/base/core/res/res/values/` path so AOSP's resource-merge
# step picks up the qalos config.xml automatically. See
# device/qalos/qalos_emulator/overlay/frameworks/base/core/res/res/values/config.xml
# for the actual overrides.
#
# This is the Tier 1 resource-overlay layer from the strip plan
# (device/qalos/qalos_emulator/AGENTS.md "Strip policy").
# ---------------------------------------------------------------------------
# DEVICE_PACKAGE_OVERLAYS is the per-device variant and is processed
# earlier than PRODUCT_PACKAGE_OVERLAYS during config. AOSP 15 still
# accepts PRODUCT_PACKAGE_OVERLAYS but emits a deprecation warning;
# DEVICE_PACKAGE_OVERLAYS is the recommended pattern for per-device
# resource overlays.
DEVICE_PACKAGE_OVERLAYS := device/qalos/qalos_emulator/overlay

# Show the qalos build id on the AVD's boot screen.
# `PRODUCT_PROPERTY_OVERRIDES` is technically deprecated in favour of
# the partition-specific `PRODUCT_<PARTITION>_PROPERTIES` lists
# (see `core/product.mk` TODO(b/117892318)). For v0 we keep the
# deprecated form because the system-visible build-id properties are
# exactly what the AOSP compat layer still wires correctly; switching
# to `PRODUCT_SYSTEM_PROPERTIES` is a drive-by for v1.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.qalos.build_id=$(BUILD_ID) \
    ro.qalos.display_build_id=$(DISPLAY_BUILD_ID)

# ---------------------------------------------------------------------------
# Locale policy. The QA team uses English and Mandarin Chinese
# only. `PRODUCT_LOCALES` is a build-time filter that ships only
# the listed language resources to system.img / system_ext.img —
# everything else (Arabic, Hindi, Japanese, Korean, etc.) is
# dropped at compile time. This is the right knob for the user's
# "keep english and mandarin chinese only" decision; a runtime
# `persist.sys.locale=…` only sets the default and does not strip
# the unused resource APKs.
#
# en_US + en_GB cover the QA team's UK English; zh_CN + zh_TW
# cover Simplified and Traditional Mandarin. Add more entries
# only with explicit owner sign-off (legal/ACCEPTABLE_USE_POLICY.md
# is the right place to record why).
# ---------------------------------------------------------------------------
PRODUCT_LOCALES := en_US en_GB zh_CN zh_TW

# ---------------------------------------------------------------------------
# Tier 1 QA Lab optimisations — system properties that flip runtime
# behaviour for a lab emulator. Mirrors the reference doc's
# "QA Lab Optimizations (Properties & Config)" block.
#
# Only properties that are verified to exist on AOSP 15.0.0_r1 are
# included here. Properties that were in the original plan but are
# not verified AOSP-15 (e.g. ro.qalaudio.allow_ac, ro.config.battery_
# saver_config_overlay, ro.system.update.disable, ro.lockscreen.disable
# .default) are listed in qalos_emulator/AGENTS.md "Strip policy" as
# v1.1 candidates. Per the plan's risk section: a no-op property is
# safe — the worst case is the test APK gets the default behaviour.
#
# ro.logd.size=16M         — larger logd buffer so instrumented builds
#                             keep more context.
# ro.config.low_ram=true   — mark the image as a low-RAM device; AOSP
#                             throttles background work accordingly
#                             (faster tests, less interference from
#                             the QA Lab's background heuristics).
# window_animation_scale=0  — instant UI for the test rig. The
#                             no-prefix form is what AOSP's
#                             `WindowManagerService` reads; the
#                             `persist.sys.` and `Settings.Global.`
#                             forms mirror the same value at runtime.
# transition_animation_scale=0 — same.
# animator_duration_scale=0 — same.
# ---------------------------------------------------------------------------
PRODUCT_PROPERTY_OVERRIDES += \
    ro.logd.size=16M \
    ro.config.low_ram=true \
    window_animation_scale=0 \
    transition_animation_scale=0 \
    animator_duration_scale=0

# ---------------------------------------------------------------------------
# Product VINTF manifest.
#
# AOSP 15's final packaging step runs vintffm --check against
# system/etc/vintf/manifest.xml (system + system_ext) and
# system/product/etc/vintf/manifest.xml (product). The emulator product
# inherits from aosp_x86_64 which does not declare any product-shipped
# HALs, so the product manifest is empty — but vintffm still requires the
# file to exist (otherwise the check fails with `NAME_NOT_FOUND` and
# aborts the build before the .img files are sealed, even when compilation
# has already succeeded).
#
# We copy an empty product manifest (vintf/product_manifest.xml) into the
# product partition via PRODUCT_COPY_FILES. The destination path is
# `system/product/etc/vintf/manifest.xml` — the dirmap /product path that
# vintffm walks.
#
# If qalos ever ships product-side HALs (vendor/qalos/qalos_emulator/hal/
# with .manifest.xml in product/etc/vintf/), this copy becomes a
# `<hal>` element in the manifest body — the file itself stays.
# ---------------------------------------------------------------------------
PRODUCT_COPY_FILES += \
    device/qalos/qalos_emulator/vintf/product_manifest.xml:system/product/etc/vintf/manifest.xml

# Note: the qalos SELinux policy overlay is wired via BoardConfig.mk
# (not here). AOSP's sepolicy build reads BOARD_SEPOLICY_DIRS from
# BoardConfig.mk; setting it in device.mk is silently ignored on
# modern AOSP. See BoardConfig.mk in this directory.
