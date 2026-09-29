# GMS Mimic / Compatibility Layer — Research Note

**Target:** AOSP 15.0.0_r1, x86_64 emulator (`qalos_emulator-userdebug`)
**Scope:** What a legitimate GMS compatibility layer looks like in AOSP, minimum viable APIs, correct architecture, build integration, and open-source references.
**Status:** Phase 1 complete (APKs downloaded + wired). Phase 2 complete (sig-spoof patch applied, commit `9c12f9b`).

---

## 1. What is microG

**microG** (microg.org, Apache 2.0) is the de-facto FLOSS reimplementation of Google Play Services. It reimplements the `com.google.android.gms` APIs so apps that call Google's proprietary APIs can run on non-Google AOSP ROMs.

### Two main packages

| Package | Role |
|---|---|
| `com.google.android.gms` (GmsCore) | Core — location, auth, FCM, maps stubs, SafetyNet stubs |
| `com.android.vending` (microG Companion / FakeStore) | Play Store replacement — licensing (BLP), billing stub, package name checker |

A third package, `com.google.android.gsf` (Google Services Framework), is also expected by some apps and by the Play Store licensing check.

### What microG implements vs. does not

- **Implements:** Fused Location Provider, Google Account Auth (OAuth2), Firebase Cloud Messaging (FCM) / Google Cloud Messaging (GCM), SafetyNet (basic), Play Games (partial), Maps API (via pluggable backends: VTM, Mapbox, OpenStreetMap), Cast (stub), DroidGuard (partial)

- **Will NOT implement:** Ads API (`com.google.android.gms.ads`), full Play Integrity (hardware-backed), Google Pay / Wallet

---

## 2. Minimum Viable GMS APIs — Prioritized

For a QA Lab emulator build the goal is to make apps *start and function* without crashing on GMS checks. Full Google server connectivity is optional.

### Tier 1 — Core / Required for almost all apps

| Package | API | Why needed |
|---|---|---|
| `com.google.android.gms` | `com.google.android.gms.common` — `GoogleApiAvailability`, `ConnectionResult` | Every GMS app calls `GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable()` at startup. Without it, apps crash immediately. |
| `com.google.android.gms` | `com.google.android.gms.auth` — `GoogleAuthUtil` / `GoogleAccountCredential` | Google Sign-In OAuth2. Most apps that have a "Sign in with Google" button need this. |
| `com.google.android.gms` | `com.google.android.gms.cloudmessaging` — `CloudMessaging` | FCM push notifications. Critical for Signal, WhatsApp, Telegram, any modern messaging app. |
| `com.google.android.gms` | `com.google.android.gms.location` — `FusedLocationProviderClient` | Any app that requests location and uses the modern FLP API. |

### Tier 2 — Common but not universal

| Package | API | Notes |
|---|---|---|
| `com.google.android.gms` | `com.google.android.gms.maps` — `MapsInitializer`, `GoogleMap` | Renders embedded Google Maps in Uber, Airbnb, etc. Without this, map views are blank but the app still runs. |
| `com.google.android.gms` | `com.google.android.gms.safetynet` — `SafetyNetApi` | Device integrity. Many banking apps check this. microG returns `MEETS_BASIC_INTEGRITY` with a spoofed CTS profile. |
| `com.google.android.gms` | `com.google.android.gms.ads` — `MobileAds`, `AdMob` | Stub only — microG does not implement ads. Apps that use AdMob will get blank ads or the test-ad fallback. |
| `com.google.android.gms` | `com.google.android.gms.tasks` — `Tasks` API | Underpins nearly all async GMS calls. Always needed. |
| `com.google.android.gms` | `com.google.android.gms.phenotype` — `Phenotype` | Used by some Google-first-party and third-party apps for feature flags. |

### Tier 3 — Optional for this project

| Package | Notes |
|---|---|
| `com.google.android.gms.cast` | Chromecast / Google Cast. Unlikely needed for a QA lab emulator. Stub is sufficient. |
| `com.google.android.gms.games` | Play Games. Only gaming apps need it. |
| `com.google.android.gms.fitness` | Google Fit. Niche. |
| `com.google.android.gms.wearable` | Wear OS companion. Not relevant. |

### Key Java package names to stub/implement

```text
com.google.android.gms
├── common/               # GoogleApiAvailability, ConnectionResult, zzx.* (IPC)
├── common/api/           # GoogleApi, GoogleApiClient, Result callbacks
├── auth/                 # GoogleAuthUtil, GoogleAccountCredential, GameAuth
├── cloudmessaging/       # CloudMessagingApi, GmsRpc
├── location/             # FusedLocationProviderClient, SettingsApi
├── maps/                 # MapsInitializer, GoogleMap, MapFragment
├── maps/model/           # LatLng, CameraPosition, Marker, Polyline, etc.
├── safetynet/            # SafetyNetApi, AttestationResponse
├── tasks/                # Task, TaskCompletionSource, Registrations
├── ads/                  # MobileAds, AdView, AdRequest (stub only)
├── phenotype/            # Phenotype (feature flags)
├── cast/                 # CastContext, CastSession (stub)
└── internal/            # Chimera IPC stubs, SafeParcel, GmsService enum
```

---

## 3. Architectural Approach

### The right pattern: System privileged app, NOT a resource overlay

A GMS layer is a **system app** (specifically a **priv-app**) — not a runtime resource overlay (RRO). The reason: GMS apps query `PackageManager` for the presence and signature of `com.google.android.gms`. Resource overlays cannot change code, manifest entries, or signatures.

Apps check:

1. Does `com.google.android.gms` exist? (package presence)

2. Does its signature match Google's official certificate? (signature check)

3. Is the service they're calling available? (AIDL bind)

microG satisfies #1 and #3. For #2 (signature), **signature spoofing** must be patched into the framework.

### Signature spoofing requirement

The `com.google.android.gms` package must report Google's official SHA-1 signature to client apps that verify it. AOSP does not do this by default. The ROM must be patched to:

1. Declare `android.permission.FAKE_PACKAGE_SIGNATURE` in `frameworks/base/core/res/AndroidManifest.xml`

2. Patch `PackageManagerService` to return Google's official signature when `com.google.android.gms` is queried by any package that holds `FAKE_PACKAGE_SIGNATURE`

microG ships patches for this in `fake-signature/src/`. LineageOS, /e/OS, CalyxOS, and iodéOS ship these patches out-of-the-box.

**For the emulator**, signature spoofing can be patched directly into the AOSP `frameworks/base` tree before building. The patch for Android 15 (API 35, letter "V") is available from the microG wiki.

### Three-package model (minimum viable)

| APK filename | Package | Role | Priv-app path |
|---|---|---|---|
| `GmsCore.apk` | `com.google.android.gms` | Core services | `/system/priv-app/GmsCore/` |
| `FakeStore.apk` | `com.android.vending` | Play Store stub (BLP licensing) | `/system/priv-app/FakeStore/` |
| `GoogleServicesFramework.apk` | `com.google.android.gsf` | Google account / checkin | `/system/priv-app/GoogleServicesFramework/` |

`com.google.android.gsf` is lightweight — it's essentially just the `GoogleLoginService` and account management that other GMS components depend on.

---

## 4. Suggested Package Structure under `device/qalos/`

```text
device/qalos/
├── qalos_emulator/           ← existing product makefile dir
│   └── ...
└── gms/                      ← NEW: GMS mimic layer
        ├── Android.mk              # assembles all prebuilt GMS packages
        ├── GmsCore/                # com.google.android.gms
        │   ├── Android.mk
        │   └── GmsCore.apk         # prebuilt from microG release
        ├── FakeStore/              # com.android.vending
        │   ├── Android.mk
        │   └── FakeStore.apk       # prebuilt from microG release
        ├── GoogleServicesFramework/ # com.google.android.gsf
        │   ├── Android.mk
        │   └── GoogleServicesFramework.apk  # prebuilt from microG
        ├── permissions/             # privapp permissions for GMS
        │   ├── privapp-permissions-gms.xml
        │   └── sysconfig-gms.xml
        └── overlay/                 # optional: framework config overrides
            └── frameworks/base/core/res/values/config.xml
                # bools: config_enableNetworkLocationOverlay=true
                # bools: config_enableFusedLocationOverlay=true
```

Alternatively, put the GMS vendor under `vendor/qalos/gms/` if following the `vendor/` convention for proprietary blobs. Both are valid; `device/` is simpler for a single-product emulator build.

---

## 5. Key AOSP Build Variables

### In `device/qalos/qalos_emulator/device.mk`

```makefile
# Inherit the GMS package set
$(call inherit-product, device/qalos/gms/gms.mk)

# OR manually:
PRODUCT_PACKAGES += \
    GmsCore \
    FakeStore \
    GoogleServicesFramework \
    com.google.android.maps.jar

# Framework config overlay for location providers
PRODUCT_PACKAGE_OVERLAYS += device/qalos/gms/overlay

# sysconfig and permissions
PRODUCT_COPY_FILES += \
    device/qalos/gms/permissions/privapp-permissions-gms.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/permissions/privapp-permissions-gms.xml \
    device/qalos/gms/permissions/sysconfig-gms.xml:$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/sysconfig/sysconfig-gms.xml
```

### In each `*/Android.mk`

```makefile
# Example: GmsCore/Android.mk
LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := GmsCore
LOCAL_PACKAGE_NAME := com.google.android.gms
LOCAL_CERTIFICATE := PRESIGNED
LOCAL_SRC_FILES := GmsCore.apk
LOCAL_MODULE_CLASS := APPS
LOCAL_PRIVILEGED_MODULE := true          # → /system/priv-app/GmsCore/
LOCAL_MODULE_SUFFIX := $(COMMON_ANDROID_PACKAGE_SUFFIX)
include $(BUILD_PREBUILT)
```

```makefile
# Example: GoogleServicesFramework/Android.mk
include $(CLEAR_VARS)
LOCAL_MODULE := GoogleServicesFramework
LOCAL_PACKAGE_NAME := com.google.android.gsf
LOCAL_CERTIFICATE := PRESIGNED
LOCAL_SRC_FILES := GoogleServicesFramework.apk
LOCAL_MODULE_CLASS := APPS
LOCAL_PRIVILEGED_MODULE := true
LOCAL_MODULE_SUFFIX := $(COMMON_ANDROID_PACKAGE_SUFFIX)
include $(BUILD_PREBUILT)
```

```makefile
# Example: FakeStore/Android.mk
include $(CLEAR_VARS)
LOCAL_MODULE := FakeStore
LOCAL_PACKAGE_NAME := com.android.vending
LOCAL_CERTIFICATE := PRESIGNED
LOCAL_SRC_FILES := FakeStore.apk
LOCAL_MODULE_CLASS := APPS
LOCAL_PRIVILEGED_MODULE := true
LOCAL_MODULE_SUFFIX := $(COMMON_ANDROID_PACKAGE_SUFFIX)
include $(BUILD_PREBUILT)
```

### Also needed: framework JAR

```makefile
# com.google.android.maps.jar — required by Maps API
include $(CLEAR_VARS)
LOCAL_MODULE := com.google.android.maps
LOCAL_MODULE_CLASS := JAVA_LIBRARIES
LOCAL_SRC_FILES := com.google.android.maps.jar
include $(BUILD_PREBUILT)
```

### Signature spoofing patch

Apply to `frameworks/base` before the build. The patch:

- Adds `android.permission.FAKE_PACKAGE_SIGNATURE` to `core/res/AndroidManifest.xml`

- Patches `services/core/java/com/android/server/pm/PackageManagerService.java` to return the spoofed Google signature for `com.google.android.gms` when the requesting app holds the spoofing permission

Patch source: `https://github.com/microg/GmsCore/wiki/Signature-Spoofing` — pick the patch matching Android 15 (API 35).

---

## 6. Open-Source References

### microG GmsCore (Apache 2.0)

| Item | URL |
|---|---|
| Main repo | https://github.com/microg/GmsCore |
| Wiki / install guide | https://github.com/microg/GmsCore/wiki |
| Signature spoofing patches | https://github.com/microg/GmsCore/wiki/Signature-Spoofing |
| AOSP build integration | https://github.com/microg/GmsCore/wiki/Building-from-source |
| Current release APKs | https://microg.org/fdroid/repo/index.xml |

**Latest stable (as of 2026-09):** GmsCore `0.3.250932` (targets GMS `25.09.32`); Companion `0.2.24.220220`

### LineageOS for microG vendor manifest (good reference)

`https://github.com/lineageos4microg/android_vendor_partner_gms` — the canonical way LineageOS integrates microG. Set `WITH_GMS=true` to activate.

### android_vendor_gms (PixelBuilds — proprietary extraction, not open-source)

`https://git.pixelbuilds.org/android/android_vendor_gms` — extracts real GMS APKs from Pixel factory images. Useful as a reference for the full package inventory, but the APKs are proprietary Google binaries. Do not use in qalos.

### BlissROMs GMS vendor (good build pattern reference)

`vendor/gms/` in BlissROMs — shows the full structure of `PRODUCT_PACKAGES`, `DEVICE_PACKAGE_OVERLAYS`, and Soong config variables. Apache 2.0 for build scripts; proprietary APKs otherwise.

---

## 7. Recommended Implementation Plan

### Phase 1 — Framework patch (highest leverage, do first)

1. Apply the signature-spoofing patch to `frameworks/base/`:

   ```bash
   cd frameworks/base
   patch -p1 -i /path/to/0002-Add-support-for-app-signature-spoofing.patch
   ```
   Use the patch labelled for **Android 15 / API 35 / letter V** from `https://github.com/microg/GmsCore/wiki/Signature-Spoofing`.

2. Add the location overlay bools to `device/qalos/gms/overlay/frameworks/base/core/res/values/config.xml`:

   ```xml
   <bool name="config_enableNetworkLocationOverlay">true</bool>
   <bool name="config_enableFusedLocationOverlay">true</bool>
   ```

### Phase 2 — Package scaffolding

3. Create `device/qalos/gms/` with the directory structure from §4.

4. Download prebuilt APKs from `https://microg.org/fdroid/repo/`:

   - `com.google.android.gms-*.apk` → `GmsCore/GmsCore.apk`

   - `com.android.vending-*.apk` → `FakeStore/FakeStore.apk`
   *(Note: microG doesn't ship GoogleServicesFramework as a separate APK — the GsfProxy handles GCM registration. `com.google.android.gsf` is only needed if using the full vendor_gms proprietary extraction.)*

5. Write the per-module `Android.mk` files.

6. Write `device/qalos/gms/Android.mk` that inherits all three modules.

### Phase 3 — Build integration

7. In `device/qalos/qalos_emulator/device.mk`, add:

   ```makefile
   $(call inherit-product, device/qalos/gms/gms.mk)
   PRODUCT_PACKAGE_OVERLAYS += device/qalos/gms/overlay
   ```

8. Add `privapp-permissions-gms.xml` (grant GmsCore the permissions it needs: `WAKE_LOCK`, `ACCESS_WIFI_STATE`, `READ_PHONE_STATE`, `INTERACT_ACROSS_USERS`, etc. — see microG wiki for the full list).

### Phase 4 — Verify

9. Build `qalos_emulator-userdebug` and boot the emulator.

10. Install an app that requires GMS (e.g. Signal, or the microG Self-Check app from F-Droid).

11. Check: does `GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable()` return `SUCCESS`? Does FCM registration succeed? Does the map in a map-dependent app render?

### Key risk

**Signature spoofing must be patched into the framework before the build.** Without it, apps that verify the GMS signature (most Google-signed apps) will refuse to communicate with GmsCore. This is a source-code patch — there is no way to achieve it with a standalone overlay or prebuilt APK alone.

### What qalos does NOT need

- **Google Play Store APK** (the real `com.android.vending` from Google) — FakeStore satisfies the package-name check and BLP licensing stub.

- **Google Maps API key** — map views will use the microG VTM backend (OpenStreetMap) by default, or can be configured to use Mapbox.

- **Hardware-backed Play Integrity** — not achievable without a real Titan M chip. SafetyNet basic passes with microG's spoofed CTS profile.

- **Ads** — microG doesn't implement them and qalos doesn't need them.

---

## Phase 1 Completion — 2026-09-20

**Done:** Real microG APK files downloaded and build wired.

### What was done

| File | Action |
|---|---|
| `device/qalos/gms/GmsCore/GmsCore.apk` | Replaced 0-byte stub with `com.google.android.gms-252432032.apk` (103 MB, v0.3.16.252432) |
| `device/qalos/gms/FakeStore/FakeStore.apk` | Replaced 0-byte stub with `com.android.vending-84022632.apk` (4 MB, v0.3.16.40226) |
| `device/qalos/gms/GsfProxy/GsfProxy.apk` | Created: downloaded `com.google.android.gsf-8.apk` (22 KB, v0.1.0) |
| `device/qalos/gms/GsfProxy/Android.mk` | Created: `BUILD_PREBUILT` module for GsfProxy |
| `device/qalos/qalos_emulator/device.mk` | Replaced `$(call add-prebuilt-system-app,...)` (unverified macro) with `PRODUCT_PACKAGES += GmsCore FakeStore GsfProxy`; updated comment with exact versions |

### APK source

- URL: `https://repo.microg.org/fdroid/repo/`

- Index: `index.xml` at that URL (verified SHA256 against published hashes)

- All three APKs include `FAKE_PACKAGE_SIGNATURE` permission (required for sig-spoof to work)

---

## Phase 2 Completion — 2026-09-20 (commit `9c12f9b`)

**Done:** Android 15 sig-spoofing patch applied to `ComputerEngine.java`, `config.xml`, and `AndroidManifest.xml`.

### What was done

The sig-spoof patch was reverse-engineered from LineageOS 22.1 (Android 15) source. Three files were modified:

#### `services/core/java/com/android/server/pm/ComputerEngine.java`

- **Static fields** (after `sProviderInitOrderSorter` ~line 382):

  - `MICROG_FAKE_SIGNATURE` — the Google cert (presented to callers)

  - `MICROG_REAL_SIGNATURE` — the microG stub cert (actual GmsCore signing)

  - `isMicrogSigned(SigningDetails)` — returns true when package signing == stub cert

  - `generateFakeSignature()` — returns the Google cert

- **`generatePackageInfo()` spoof block** (~line 1564): swaps stub → Google cert:

  ```java
  if (isMicrogSigned(p.getSigningDetails())) {
      packageInfo.signatures = new Signature[]{generateFakeSignature()};
  }
  ```

#### `core/res/res/values/config.xml`

Added `config_fusedLocationOverlayProviderClasses` so the fused-location overlay provider can be replaced at runtime by microG's `LocationOverlayProvider`.

#### `core/res/AndroidManifest.xml`

Added `FAKE_PACKAGE_SIGNATURE` with `protectionLevel="signature|privileged"` — required for GmsCore to declare its fake-signature meta-data.

### Patch application

```bash
python tools/apply-sig-spoof.py
```

### Key design notes

- **Spoof lives in `ComputerEngine`** (not `PackageManagerService`) — Android 13+ moved the Computer/snapshot architecture here; `checkSignaturesInternal()` does NOT need code changes (spoof is at the API return level).

- **`generatePackageInfo()` is the correct injection point** — this is what `PackageManager.getPackageInfo()` returns to callers; the swap happens here before the result reaches any app.

- **`checkSignaturesInternal()` is NOT patched** — signature comparison between packages (e.g. app vs GmsCore) still works correctly because GmsCore's real signing is what gets compared internally; only the *returned* signature to external callers is spoofed.

- **microG APKs declare `fake-signature` meta-data** pointing to `MICROG_FAKE_SIGNATURE`; the framework reads this and applies the swap automatically.

### Reference sources

- LineageOS 22.1 `ComputerEngine.java`: https://github.com/LineageOS/android_frameworks_base/lineage-22.1/services/core/java/com/android/server/pm/ComputerEngine.java

- microG project: https://microg.org/

- Original sig-spoof gerrit (Android 8–12): LineageOS gerrit #411386

### Still needed (Phase 3+)

1. ~~**Signature spoofing patch**~~ — ✅ **DONE** (commit `9c12f9b`, applied via `tools/apply-sig-spoof.py`)

2. ~~**AOSP source extraction**~~ — ✅ **DONE** (files extracted to `D:\aosp-extracted\`)

3. **privapp-permissions** — GmsCore needs extra permissions (WAKE_LOCK, ACCESS_WIFI_STATE, etc.) via `privapp-permissions-gms.xml`

4. **Build verification** — boot the emulator and run `dumpsys package com.google.android.gms` or install Signal/microG Self-Check

### Notes

- The Java stub files (`GmsCoreStub.java`, `FakeStoreStub.java`, `common/`, `auth/`, `location/`, `permissions/`) are dead code (not used with `BUILD_PREBUILT`). They can be removed in a cleanup pass or kept as reference.

- The `$(call add-prebuilt-system-app,...)` macro was not a standard AOSP macro — it silently expanded to nothing in a standard AOSP build. Replaced with `PRODUCT_PACKAGES +=` which is the correct AOSP 15 method.

- GmsCore v0.3.16 includes native libs for all 4 ABIs (arm64-v8a, armeabi-v7a, x86, x86_64) — correctly targets the x86_64 emulator.
