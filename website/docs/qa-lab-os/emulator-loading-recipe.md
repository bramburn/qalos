---
id: emulator-loading-recipe
title: Emulator loading recipe — what the emulator needs to boot qalos images
sidebar_label: Emulator loading recipe
sidebar_position: 13
description: The minimal file set the Android emulator needs (kernel, ramdisk.img, system.img, userdata.img — no super/vbmeta/boot), the verified state of the qalos sysdir, AVD config fixes, the scripted cold-boot command, verification steps, and fallbacks.
---

# Emulator loading recipe

What the Android emulator actually requires to boot a qalos image,
plus the verified state of our sysdir and the exact cold-boot
invocation. Verified 2026-09-13 against the attempt-11 artifacts
and a live stock control boot. Companion pages:
[`aosp-15-build-journal.md`](./aosp-15-build-journal.md) (build) and
[`emulator-boot-diagnosis.md`](./emulator-boot-diagnosis.md) (boot
failure diagnosis).

## The minimal file set

The emulator synthesizes its partition table from **whatever files
exist** in the sysdir. It needs only:

- **`kernel-ranchu`** — the guest kernel (a prebuilt; see below)
- **`ramdisk.img`** — initramfs (may be an empty stub)
- **`system.img`** — the system partition (raw ext4 for qalos)
- **`userdata.img`** — data partition (provisioned by `-wipe-data`)
- **optional:** `cache.img`, `vendor.img`

**No `super.img`, `vbmeta.img`, or `boot.img`.** The qalos product
is a legacy (non-dynamic-partition), no-AVB build — those files do
not exist and are not needed. A bare legacy system.img boots fine.

The kernel is **not** in `out/` — it is a prebuilt:
`prebuilts/qemu-kernel/x86_64/5.4/kernel-qemu2` (AOSP 15, 5.4.78,
17,213,216 B bzImage, SHA256-verified). The emulator picks it up
from the sysdir as `kernel-ranchu`.

## Verified state of the qalos sysdir

`D:\qalos\.pi\out\qalos-sys-img\android-35-ext15\default\x86_64\`
(verified 2026-09-13):

| File | Size | Verdict |
|---|---|---|
| `system.img` | 2,147,483,648 B (2 GiB) | **OK** — byte-identical to the attempt-11 build output (real qalos image) |
| `kernel-ranchu` | 17,213,216 B | **OK** — bzImage, SHA256-verified AOSP 15 `5.4/kernel-qemu2` |
| `ramdisk.img` | 638 B | **WRONG — must be replaced.** This is the qalos build's `debug_ramdisk` stub (gzip `1f 8b 08 00`, 3072 B cpio, only dev nodes + a few directories + `system/etc/ramdisk/build.prop`, **NO `/init`, NO `init.rc`, NO `fstab`, NO kernel modules**). It is emitted because `aosp_x86_64.mk` defaults `INITRAMFS_IMAGE` to `debug_ramdisk`. The kernel has **no built-in initramfs** either (binary scan: 0 CPIO hits across 17 MB; cf. the stock API-35 kernel which has 3 newc-cpio hits). The combo produces an unbootable image — kernel boots, then `VFS: Cannot open root device "vda"` (virtio_blk is a module, the empty ramdisk has no `lib/modules/*.ko` to load it). **Verified T3 2026-09-13.** Fix: set `INITRAMFS_IMAGE := initrd` in `BoardConfig.mk` (the standard AOSP 15 target built by `system/core/rootdir/Android.mk`) — produces a real initramfs with `/init`, `init.rc`, `fstab.qalos_emulator`, `ueventd.rc`, `default.prop`, and the required modules. See `aosp-15-build-journal.md` §"Attempt 13 (initramfs fix)". |
| `cache.img` | 69,206,016 B (66 MB) | OK |
| `userdata.img` | 12,884,901,888 B (12.8 GB) | **WRONG — stock `google_apis_playstore` copy.** Must be replaced with the qalos build's **550 MB** `userdata.img` (from `D:\qalos\.pi\out\qalos-cn-guangzhou-2026-09-13\`) so `-wipe-data` provisions the qalos preset. |
| `cache.img.qcow2`, `userdata.img.qcow2` | ~197 KB each | Emulator-generated COW overlays from the failed boot attempts — benign; deletable. |

**Missing but benign:** `encryptionkey.img`, `advancedFeatures.ini`,
`data\`, `kernel_cmdline.txt` (copy `kernel_cmdline.txt` from a
stock AVD if you want it materialized).

**Do NOT copy `VerifiedBootParams.textproto`** into the sysdir —
it is stock-AVB-tied; the qalos userdebug build has **no AVB**
(unverified boot). Copying it would lie about the boot verification
chain.

## AVD config fixes

`C:\Users\bramburn\.android\avd\pixel_8_hsk.avd\config.ini`
currently contains **literal placeholder values** that must be
removed before this AVD is a usable qalos launcher:

- `avd.id=<build>` — remove the key (the AVD name is the id).
- `disk.dataPartition.path=<temp>` — remove the key (leave it
  unset so the emulator manages the data image in the AVD dir;
  a literal `<temp>` path is why the data partition provisioning
  cannot be relied on).
- `tag.id=google_apis_playstore` — the qalos image is **not** a
  playstore image; for a stock-matching tag it should be
  `google_apis`. Leaving playstore only means the emulator
  believes it is a playstore image, which it isn't.
- `hw.ramSize=4G` — **honored**; matches the 4 GiB the kernel
  reports (Total pages 1032035). Leave as-is.
- `image.sysdir.1=D:\qalos\.pi\out\qalos-sys-img\android-35-ext15\default\x86_64\`
  — the qalos sysdir override (verified line).

## Scripted cold boot command

```powershell
emulator.exe -avd pixel_8_hsk -no-window -no-snapshot -no-snapshot-load -no-snapshot-save -no-audio -no-boot-anim -gpu swiftshader -accel auto -wipe-data -verbose -show-kernel
```

Emulator 37.x flags:

- `-gpu` accepts `auto|host|software|lavapipe|swiftshader|swangle`
  — **`swiftshader_indirect` no longer exists** (older qalos notes
  using it will fail).
- `-accel` accepts `auto|off|on`.
- Host capability check: `emulator.exe -accel-check` reports
  `WHPX(10.0.17763) is installed and usable` on this machine.

## Verification steps

```powershell
adb -e wait-for-device
adb -e shell getprop ro.product.brand    # → QA Lab (QALab)
adb -e shell getprop sys.boot_completed  # → 1
```

## Fallbacks

- **Stock ramdisk substitute:** if a full initramfs is ever needed,
  use the stock API-35 AVD's real ramdisk (**1,873,527 B**).
- **`vendor.img` copy experiment:** the sysdir currently has no
  `vendor.img`, so there are no vendor HALs. If the guest boots
  and then throws HAL errors, copying the stock `vendor.img` into
  the sysdir is the next experiment (not yet tried).
- **`root=/dev/vda` vs `root=/dev/vda1`:** the canonical emulator
  guest cmdline uses `root=/dev/vda1` (see the diagnosis page).
  The qalos legacy single-partition system runs `root=/dev/vda`;
  keep `kernel.parameters=root=/dev/vda init=/init` in the AVD for
  the qalos system.img. A bare system.img run typically needs
  those explicit values — the emulator's built-in defaults don't
  carry them.
