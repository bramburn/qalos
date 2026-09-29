# device/google/cheetah — Pixel 7 Pro docs anchor (NO DEVICE TREE HERE)

**This directory intentionally contains only documentation.** The real
Pixel 7 Pro (cheetah) device tree is **already public in AOSP 15** and is
fetched by `repo sync` via the qalos manifest (`default.xml` →
`upstream.xml`):

| What | Where (after `repo sync`) |
| --- | --- |
| Cheetah product makefile | `device/google/pantah/aosp_cheetah.mk` |
| Cheetah device config | `device/google/pantah/device-cheetah.mk` |
| Cheetah board config | `device/google/pantah/cheetah/BoardConfig.mk` |
| Shared GS201 (Tensor G2) platform | `device/google/gs201/` |
| Sepolicy | `device/google/pantah-sepolicy/`, `device/google/gs201-sepolicy/` |
| Kernel 5.10 prebuilts | `device/google/pantah-kernels/5.10/` |

The qalos products consume these directly:
`device/qalos/qalos_cheetah/qalos_cheetah.mk` inherits
`device/google/pantah/aosp_cheetah.mk`, and its `BoardConfig.mk`
`-include`s `device/google/pantah/cheetah/BoardConfig.mk`.

> Historical note: an earlier version of this README claimed Pixel trees
> were private and had to come from a community fork (LineageOS,
> PixelExperience, nickel-jn). That was wrong for AOSP 15 — `pantah` was
> never removed from the public manifest, and the PixelExperience /
> nickel-jn repos no longer exist. LineageOS's
> `android_device_google_cheetah` is also just a 4-file extraction stub;
> its real content lives in `android_device_google_pantah`. Verified
> 2026-09-25 against `android-15.0.0_r1`.

## What is still missing: proprietary blobs

AOSP ships no proprietary binaries. `device-cheetah.mk` pulls them in via
`$(call inherit-product-if-exists, …)`, so the build configures without
them, but a device image without blobs has no camera/audio/radio HALs.

Populate `vendor/google_devices/` (NOT this directory) with **one** of:

### Option A — Google's driver zips (partially available)

Download the "Pixel 7 Pro binaries for Android 15.0.0" package matching
your AOSP release from
<https://developers.google.com/android/drivers> and run the extracted
self-extracting script at the top of the AOSP tree.

⚠️ **Corrected 2026-08-28 — this is only half the story.** For build
`AP3A.241005.015.A2` (= tag `android-15.0.0_r1`) the package was downloaded,
checksum-verified and unpacked. It populates
`vendor/google_devices/cheetah/` **only** — 21 files, 914 MB. It does **not**
populate `vendor/google_devices/gs101/`, and Google publishes no
`google_devices-gs101-*.tgz`. The per-device package model means the shared
GS101/Tensor-G2 platform blobs are a separate, non-public artefact.

So the cheetah `-include` path resolves, but `RELEASE_KERNEL_CHEETAH_DIR`
remains undefined and the release config is still missing. See
`.pi/AOSP-BUILD-STATUS.md` §3.8.

### Option A2 — the GS101 platform blobs (required, NOT public)

`vendor/google_devices/gs101/prebuilts/` carries `RELEASE_KERNEL_CHEETAH_DIR`,
`RELEASE_GOOGLE_CHEETAH_RADIO_DIR` and the matching 6.1 kernel. It is
distributable only through the Android **Device Preview Program**
(<https://developers.google.com/android/blobs-preview>, sign-in required) or a
partner release. There is no public download. Without it, `qalos_cheetah`
cannot be lunched.

### Option B — LineageOS extraction tooling (from a device or factory image)

```bash
cd /home/bramburn/aosp
git clone -b lineage-22.1 https://github.com/LineageOS/android_device_google_pantah \
    device/google/pantah-lineage   # anywhere; it is tooling + lineage deltas
# then follow its README / extract-files.py to pull blobs from a stock
# Pixel 7 Pro or a factory image.
```
This is only needed if you can't use the Google driver zips (e.g.
license constraints). Note the LineageOS flow also expects its own gs201
fork (`lineage.dependencies`) and writes lineage-flavoured vendor
makefiles; the qalos products are tested against the plain-AOSP flow.

## After populating blobs

`lunch qalos_cheetah-userdebug` (or `qalos_cheetah_slim-userdebug`)
should configure and build. See "How the qalos layer is wired" below.

## How the qalos layer is wired (IMPORTANT)

The qalos products use `TARGET_DEVICE=qalos_cheetah` /
`qalos_cheetah_slim`, **not** `cheetah`. AOSP 15 resolves
`TARGET_DEVICE_DIR` by searching `device/` and `vendor/` for
`*/$(TARGET_DEVICE)/BoardConfig.mk`
(`build/make/core/board_config.mk`), so:

- `device/qalos/qalos_cheetah/BoardConfig.mk` is what gets loaded; it
  `-include`s `device/google/pantah/cheetah/BoardConfig.mk` for the real
  board config.

- Build output lands in `out/target/product/qalos_cheetah/` (not
  `.../cheetah/`).

- Build fingerprints are computed by AOSP as
  `qalos/qalos_cheetah/qalos_cheetah:<version>/<id>/<num>:<variant>/<tags>`.

## Manifest

No manifest change is needed for the device tree (pantah/gs201 are
already in `upstream.xml`). If you adopt the LineageOS flow you may add
its repos as `<project>` entries with a custom remote; see `default.xml`
for the existing pattern.
