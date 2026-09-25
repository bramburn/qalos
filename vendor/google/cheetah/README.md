# vendor/google/cheetah — Pixel 7 Pro proprietary blobs (VENDORED STUB)

This directory should contain Pixel 7 Pro (cheetah)-specific proprietary
binaries that aren't part of AOSP. These include:
- Camera HAL (libcamerahalserver.so, etc.)
- Audio HAL (audio.primary.taro.so)
- Sensors HAL (sensors.taro.so)
- Power HAL
- Various vendor-specific libraries

## How to populate

**Run the `extract-files.sh` script** that came with the device tree:

```bash
cd /home/bramburn/aosp
cd device/google/cheetah   # after populating from community fork
./extract-files.sh
```

This downloads binaries from
https://developers.google.com/android/drivers (the Pixel 7 Pro vendor
binary distribution for the build ID matching your AOSP source). It will
populate:
- `vendor/google/cheetah/` — cheetah-specific blobs (this directory)
- `vendor/google/raviole/` — shared Pixel 6/7/7 Pro blobs (separate dir)

If you cannot use the Google distribution (license issues, no network
access from inside China, etc.), extract them from a Pixel 7 Pro running
stock Android with `adb pull` from `/vendor` and `/system/vendor`.

## Legal

The proprietary blobs are licensed under the device OEM's terms. For
Pixel devices, this is Google's standard proprietary license. Distribution
in a commercial context requires KYC per `legal/KYC.md`.
