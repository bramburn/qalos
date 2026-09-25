# vendor/google/cheetah — LEGACY path, do not put blobs here (DOCS ONLY)

**The Pixel 7 Pro proprietary blobs do NOT live in this directory for
AOSP 15 builds.** This is the old (AOSP ≤ 13-era) vendor path; it is kept
only as a documentation anchor so "where do the blobs go" has a greppable
answer.

The modern path, referenced by `device/google/pantah/device-cheetah.mk`
and `device/google/pantah/cheetah/BoardConfig.mk`, is:

- `vendor/google_devices/pantah/` — cheetah device blobs
  (`device-vendor-cheetah.mk`, prebuilts, proprietary/)
- `vendor/google_devices/gs201/` — shared Tensor G2 platform blobs
- `vendor/google_devices/cheetah/` — additional cheetah proprietary
  board config (`BoardConfigVendor.mk`)

Populate them from Google's driver zips
(<https://developers.google.com/android/drivers>) — see
`device/google/cheetah/README.md` for the full recipe.

## What used to live here

Camera HAL (libcamerahalserver.so), audio HAL (audio.primary.taro.so),
sensors HAL (sensors.taro.so), power HAL and other vendor libraries.
Under AOSP 15's pantah layout these same binaries are imported from
`vendor/google_devices/…` via `inherit-product-if-exists`.

## Legal

The proprietary blobs are licensed under Google's proprietary license;
downloading them requires accepting the driver-zip terms. Distribution in
a commercial context requires KYC per `legal/KYC.md`.
