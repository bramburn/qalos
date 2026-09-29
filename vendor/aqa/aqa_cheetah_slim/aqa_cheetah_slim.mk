# vendor/aqa/aqa_cheetah_slim/aqa_cheetah_slim.mk
#
# Slim Pixel 7 Pro (cheetah) PLUS the aqa_server automation daemon.
# Strips non-essential UI packages; keeps the Telephony/SMS/RIL stack, Camera,
# webview and Settings so phone/SMS QA flows work. Headless-friendly.

$(call inherit-product, device/google/pantah/aosp_cheetah.mk)
$(call inherit-product, vendor/aqa/aqa_cheetah_slim/device.mk)

PRODUCT_NAME := aqa_cheetah_slim
# MUST equal this directory's name — see aqa_cheetah_full.mk for the
# TARGET_DEVICE_DIR rationale. Also keeps PRODUCT_OUT distinct from the full
# product (out/target/product/aqa_cheetah_slim).
PRODUCT_DEVICE := aqa_cheetah_slim
PRODUCT_BRAND := AQA
PRODUCT_MODEL := Pixel 7 Pro (AQA Slim)

PRODUCT_PACKAGES += aqa_server

# Force-keep the telephony + SMS stack: this IS the QA flow. AOSP's
# aosp_cheetah.mk already includes these; the explicit re-add is defensive and
# a no-op if the module is present only once.
PRODUCT_PACKAGES += \
    TeleService \
    TelephonyProvider \
    CarrierDefaultApp \
    MmsService \
    Messaging \
    Camera2 \
    webview \
    Settings

# Strip non-essentials.
#
# There is NO `PRODUCT_PACKAGES_REMOVE` variable in AOSP — assigning to it is
# silently inert, so the packages would still ship. The supported mechanism is
# to filter the accumulated list, exactly as
# device/qalos/qalos_cheetah_slim/qalos_cheetah_slim.mk does.
#
# $(filter-out ...) is a no-op for names not in $(PRODUCT_PACKAGES), so
# defensive entries (e.g. QuickSearchBox, removed from AOSP 15) cost nothing.
#
# WARNING: removing SystemUI means no status bar, notification shade or
# keyguard; removing Launcher3QuickStep leaves no home app. The device still
# boots and is driven over adb / aqa_server, which is the intent for headless
# QA rigs — but this image is NOT an interactive daily driver.
PRODUCT_PACKAGES := $(filter-out \
    Launcher3QuickStep \
    SystemUI \
    DeskClock \
    Calculator \
    Music \
    Gallery2 \
    Browser2 \
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
    QuickSearchBox \
    WallpaperPicker2 \
    LiveWallpapers \
    LiveWallpapersPicker \
    ThemePicker \
    BluetoothMidiService \
    NfcNci, \
    $(PRODUCT_PACKAGES))

# Bluetooth is deliberately NOT filtered: telephony QA on some flows expects
# the BT stack present. Drop it here if a rig proves otherwise.

PRODUCT_PROPERTY_OVERRIDES += \
    ro.aqa.mode=slim \
    ro.debuggable=1

# No BUILD_FINGERPRINT override — see aqa_cheetah_full.mk.