# qalos Pixel 7 Pro (cheetah) â€” slim build
#
# Inherits from qalos_cheetah (vanilla), then strips non-essential packages
# and forces the slim keep-list. Keeps:
#   toybox, adbd, logcat, screencap, screenrecord, uiautomator,
#   webview, android.webkit, Settings, Camera2, Dialer,
#   TeleService, MmsService, messaging,
#   am, pm, input, settings, dumpsys, cmd,
#   SurfaceFlinger, ART, core framework + system_server

$(call inherit-product, device/qalos/qalos_cheetah/qalos_cheetah.mk)

# --- Release config ---------------------------------------------------------
# Same pin as qalos_cheetah: AOSP 15 aborts with "No release config set for
# target" (build/make/core/release_config.mk:270) when TARGET_RELEASE is unset
# and ALL_RELEASE_CONFIGS_FOR_PRODUCT is empty for this product.
TARGET_RELEASE := trunk_staging

PRODUCT_NAME := qalos_cheetah_slim
# Same physical device as qalos_cheetah, but a DISTINCT value so the slim
# product gets its own TARGET_DEVICE_DIR (this directory, via the
# */$(TARGET_DEVICE)/BoardConfig.mk search in board_config.mk) and its own
# PRODUCT_OUT (out/target/product/qalos_cheetah_slim) â€” otherwise vanilla
# and slim builds would overwrite each other in
# out/target/product/qalos_cheetah. See qalos_cheetah.mk for the full
# rationale.
PRODUCT_DEVICE := qalos_cheetah_slim
PRODUCT_BRAND := qalos
PRODUCT_MODEL := qalos slim for Pixel 7 Pro

# Strip non-essentials.
#
# $(filter-out ...) is a no-op for any name not currently in
# $(PRODUCT_PACKAGES), so defensive entries (e.g. Browser2, which AOSP 15
# no longer ships) cost nothing â€” the same convention documented in
# device/qalos/qalos_emulator/device.mk.
#
# WebViewGoogle and Bluetooth are deliberately NOT in this list: they are
# force-kept below, so filtering them here would be a misleading no-op.
#
# NOTE: removing SystemUI means no status bar, notification shade, or
# keyguard â€” the device still boots (to a blank fullscreen) and is driven
# over adb. That is intentional for headless QA rigs, but the slim image
# is NOT suitable as an interactive daily driver. Removing
# Launcher3QuickStep likewise leaves no home app (launch via
# `am start`/`monkey`).
PRODUCT_PACKAGES := $(filter-out \
    Launcher3QuickStep \
    SystemUI \
    DeskClock \
    Calculator \
    Music \
    Gallery2 \
    Browser2 \
    Contacts \
    Email \
    Calendar \
    DocumentsUI \
    SoundRecorder \
    Provision \
    ManagedProvisioning \
    PrintSpooler \
    ExternalStorageProvider \
    DownloadProvider \
    CaptivePortalLogin \
    EasterEgg \
    BasicDreams \
    PacProcessor \
    PicoTts \
    webview-shell \
    NfcNci \
    TrichromeChrome, \
    $(PRODUCT_PACKAGES))

# Force keep essentials (in case any got removed by upstream changes).
# webview + WebViewGoogle together are fine: the Google provider declares
# the override relationship with the AOSP webview module.
PRODUCT_PACKAGES += \
    Camera2 \
    Dialer \
    TeleService \
    MmsService \
    messaging \
    webview \
    Settings \
    WebViewGoogle \
    Bluetooth

# No BUILD_FINGERPRINT override â€” AOSP computes it with the real variant
# and tags (see qalos_cheetah.mk for the rule and rationale).
