# Phase 2: Signature-Spoofing Patch (Android 15 / AOSP 15.0.0_r1)

## What this patch does

Injects the microG signature-spoofing mechanism so Google Play Services (GmsCore)
can impersonate the real Google signature at the PackageManager level.

**Spoof mechanism:** GmsCore is signed with a microG stub certificate. Apps that
call `PackageManager.getPackageInfo(pkgName, GET_SIGNATURES).signatures[0]` expect
the real Google cert. The patch intercepts `generatePackageInfo()` in
`ComputerEngine` and swaps the microG stub cert for Google's real cert before
returning the result to callers.

## Files modified

| Source path | Patch target |
|---|---|
| `services/core/java/com/android/server/pm/ComputerEngine.java` | AOSP tree |
| `core/res/res/values/config.xml` | AOSP tree |
| `core/res/AndroidManifest.xml` | AOSP tree |

## Injection points

### ComputerEngine.java — 2 injections

**1. Static fields + helpers** (after `sProviderInitOrderSorter`, ~line 382):
- `MICROG_FAKE_SIGNATURE` — the Google cert used to fool callers
- `MICROG_REAL_SIGNATURE` — the microG stub cert GmsCore is actually signed with
- `isMicrogSigned(SigningDetails)` — returns true when package signing == stub cert
- `generateFakeSignature()` — returns the Google cert

**2. `generatePackageInfo()` spoof block** (before `return packageInfo;`, ~line 1564):
```java
if (isMicrogSigned(p.getSigningDetails())) {
    packageInfo.signatures = new Signature[]{generateFakeSignature()};
}
```

### config.xml — fused-location overlay provider

Added `config_fusedLocationOverlayProviderClasses`:
```xml
<string name="config_fusedLocationOverlayProviderClasses" translatable="false">
    com.google.android.gms.fusedlocationoverlay.provider.LocationOverlayProvider
</string>
```

### AndroidManifest.xml — FAKE_PACKAGE_SIGNATURE permission

Added:
```xml
<permission android:name="android.permission.FAKE_PACKAGE_SIGNATURE"
            android:protectionLevel="signature|privileged" />
```

## Source / Reference

- **Reference implementation:** LineageOS 22.1 (Android 15) `ComputerEngine.java`
  https://github.com/LineageOS/android_frameworks_base/lineage-22.1
- **microG project:** https://microg.org/
- **LineageOS microG patch:** LineageOS/android_frameworks_base ~2019 — the
  canonical sig-spoof patch for Android 8–15

## Applying the patches

```bash
# Apply all three patches from the AOSP source root:
python tools/apply-sig-spoof.py

# Then rebuild services/core:
m -j$(nproc)
```

## Phase history

- **Phase 1 (commit `47b683e`):** microG APKs downloaded + wired in `device.mk`
- **Phase 2 (this patch):** signature-spoofing framework patch
- **Phase 3:** (planned) GmsCore / GsfProxy / FakeStore APK build verification
