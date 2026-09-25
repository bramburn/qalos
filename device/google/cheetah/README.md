# device/google/cheetah — Pixel 7 Pro device tree (VENDORED STUB)

**This directory is intentionally empty in the qalos repo.** It is a
placeholder for Google's cheetah (Pixel 7 Pro) device tree, which must be
populated from a community fork before building.

## Why it's empty

Google's Pixel device trees are in their **private** Android repo at
`https://cs.android.com/android/_/android/platform/device/google/cheetah/`
(not publicly accessible). For AOSP, Google moved Pixel trees out of the
public AOSP manifest around AOSP 14. The qalos manifest inherits
`upstream.xml` (a verbatim copy of AOSP's default.xml at
android-15.0.0_r1), which no longer references cheetah.

## How to populate

Pick ONE of these community sources and clone into this directory:

### Option A — LineageOS device tree (recommended)
```bash
cd /home/bramburn/aosp
git clone https://github.com/LineageOS/android_device_google_cheetah \
    device/google/cheetah
```

This gives you `BoardConfig.mk`, `device.mk`, `aosp_cheetah.mk`, kernel
config, and `extract-files.sh` for proprietary blobs.

### Option B — PixelExperience
```bash
cd /home/bramburn/aosp
git clone https://github.com/PixelExperience-Devices/device_google_cheetah \
    device/google/cheetah
```

### Option C — Generic community fork (nickel-jn, etc.)
```bash
cd /home/bramburn/aosp
git clone https://github.com/nickel-jn/cheetah device/google/cheetah
```

## After populating

1. Verify the `aosp_cheetah.mk` product makefile exists.
2. Run `./extract-files.sh` from inside `device/google/cheetah/` to pull
   proprietary blobs into `vendor/google/cheetah/` and
   `vendor/google/raviole/` (downloads from
   https://developers.google.com/android/drivers, requires the build
   fingerprint).
3. Then `lunch qalos_cheetah-userdebug` should configure successfully.

## How the qalos layer is wired (IMPORTANT)

The qalos products use `TARGET_DEVICE=qalos_cheetah` /
`qalos_cheetah_slim`, **not** `cheetah`. AOSP 15 resolves
`TARGET_DEVICE_DIR` by searching `device/` and `vendor/` for
`*/$(TARGET_DEVICE)/BoardConfig.mk`
(`build/make/core/board_config.mk`), so:

- `device/qalos/qalos_cheetah/BoardConfig.mk` is what gets loaded; it
  `-include`s this tree's `BoardConfig.mk` for the real board config.
- This tree's own `BoardConfig.mk` must NOT be the only match for the
  `qalos_cheetah` search path — two matches abort the build with
  "Multiple board config files".
- Build output lands in `out/target/product/qalos_cheetah/` (not
  `.../cheetah/`).
- Build fingerprints are computed by AOSP as
  `qalos/qalos_cheetah/qalos_cheetah:<version>/<id>/<num>:<variant>/<tags>`.

### Vendor-blob caveat

Some extraction tooling generates `vendor/*/Android.mk` files gated on
`ifeq ($(TARGET_DEVICE),cheetah)`. With the qalos products
`TARGET_DEVICE` is `qalos_cheetah[_slim]`, so such gates would silently
skip every blob module (broken vendor image). If the first build is
missing `/vendor` content, check the generated makefiles for
`TARGET_DEVICE` conditionals and relax the gate (or add the qalos device
names to it).

## Manifest

Once populated, you may also want to add this as a `<project>` entry in
`default.xml` (with a custom remote pointing to the community fork
instead of Google) so subsequent `repo sync` re-fetches the source. See
`default.xml` for the existing pattern.
