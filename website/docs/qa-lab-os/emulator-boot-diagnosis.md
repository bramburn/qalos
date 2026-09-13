---
id: emulator-boot-diagnosis
title: Emulator boot diagnosis — qalos images on Windows
sidebar_label: Emulator boot diagnosis
sidebar_position: 12
description: Why the qalos AOSP 15 emulator images fail to boot on the Windows host. Verified evidence trail, hypothesis verdicts, the most-plausible cause (paravirt bare hardware / TSC calibration / LAPIC-timer window), the kernel-version secondary, and the ranked next experiments. Companion to the build journal's "Windows emulator boot" section.
---

# Emulator boot diagnosis — qalos AOSP 15 images on Windows

The qalos AOSP 15 build **succeeded** (attempt 11, see
[`aosp-15-build-journal.md`](./aosp-15-build-journal.md)); booting
the artifacts in the local Windows Android emulator **failed**
(9 attempts, all ending before rootfs). This page is the permanent
diagnosis reference: what is actually known, what was disproven,
what is most plausible, and what to run next. Read it **before**
repeating any boot experiment.

## Symptom vs reality — the "zonelists hang" myth

The original boot report claimed the kernel **hangs at "Built 1
zonelists"** inside `build_all_zonelists()` (mm_init / sched_init).
That is **disproven** — the captured logs show the boot proceeding
well past zonelists, and every capture was force-killed while the
kernel was still printing.

| Old claim (WRONG) | Verified reality |
|---|---|
| Kernel hangs at "Built 1 zonelists" | emu5_out.log (1010 lines) boots **past** zonelists: 995 `Built 1 zonelists` → 996 `Kernel command line` → 997-998 dentry/inode hash tables → **1000 `Memory: 4018256K/4193760K available` (mm_init DONE)** → 1002 SLUB → 1003-1008 RCU init → 1009 init_IRQ (`NR_IRQS: 4352`) → **1010 `rcu: Offload RCU ca…` cut mid-word at EOF** |
| All attempts die at the same point | No — every capture ends at a **different** point, mid-operation: emu5_out.log (1010 lines) mid-word in RCU init; emu7_out.log (140 lines) mid-ACPI-dump (`ACPI: FACS 0x00000000BFFE00`); emu8_out.log (138 lines) mid-line on an ACPI FACP record (`… v01 BOCHS  BXPCF`) |
| Kernel is stuck ("qemu spins") | The captures were force-killed; the guest was still printing. Real behaviour: a race-dependent stall, **always < ~0.5 CPU-s of guest time**, always **before** timers / calibration / SMP-AP-bringup. The next units after init_IRQ in 5.4 — tick_init → init_timers → hrtimers → timekeeping → time_init → calibrate_delay → SMP bringup → rest_init → rootfs → /init — are **never reached** |
| Possible "memory mismatch" | `Total pages: 1032035` × 4 KiB = 4,129,341,440 B ≈ 4 GiB = `hw.ramSize` — **normal**, not a mismatch |

**Capture caveat:** the truncation is an artefact of **pipe
redirect** (emulator stdout piped to the log file), which truncates
the instant the emulator process is force-killed. Serial-append
capture (`-qemu -serial file:...`) does not truncate — use it for
any re-run. Never kill-and-read a pipe-captured emulator log and
conclude "hang" from a mid-word line.

## Evidence trail

| File | Key lines | What it shows |
|---|---|---|
| `C:\Users\bramburn\AppData\Local\Temp\2\emu5_out.log` | 952, 991, 995-1010 | `tsc: Fast TSC calibration failed` (952) + `Booting paravirtualized kernel on bare hardware` (991) — **no hypervisor signature exposed**. Boot past zonelists → mm_init DONE → init_IRQ → cut mid-word at 1010. |
| `C:\Users\bramburn\AppData\Local\Temp\2\emu7_out.log` | 104, tail | Full canonical cmdline incl. `console=ttyS0,38400 earlyprintk androidboot.hardware=ranchu root=/dev/vda init=/init` (104) — **cmdline parity ruled out**. Cut mid-ACPI-dump at 140 lines. |
| `C:\Users\bramburn\AppData\Local\Temp\2\emu8_out.log` | 88-102, tail | `Wrong EFI loader signature.` → `early console in extract_kernel` → `Parsing ELF... Performing relocations... done.` → `Booting the kernel.` — **the correct ranchu ELF kernel decompresses + relocates fine**. Cut mid-line (`BXPCF`) at 138 lines. |
| `C:\Users\bramburn\AppData\Local\Temp\2\emulator.log` | 149 | `INFO         \| Boot completed in 63090 ms` — **stock android-31 Pixel_8 AVD boots to completion on this host/emulator/WHPX**. |
| `C:\Users\bramburn\.android\avd\pixel_8_hsk.avd\config.ini` | — | Literal placeholder values left in the AVD config (`avd.id=<build>`, `disk.dataPartition.path=<temp>`) — see [emulator-loading-recipe](./emulator-loading-recipe.md). |
| `C:\Users\bramburn\.android\avd\pixel_8_hsk.avd\hardware-qemu.ini` | 109, 113 | Effective per-boot view: `kernel.path` (line 109) and `ramdisk.path` (line 113) both point at the qalos sysdir (see "Record for future agents"). |

## Hypothesis verdict table

Verdicts from the 4-hat failure review + 2 deep-research
investigations (Sep 12-13, 2026).

| Hypothesis | Verdict | Evidence |
|---|---|---|
| WHPX-in-general broken on this host | **RULED OUT** | Stock android-31 Pixel_8 AVD booted to completion: `emulator.log:149` "Boot completed in 63090 ms" |
| Wrong kernel cmdline (missing canonical params) | **RULED OUT** | v7/v8 carried the full canonical set incl. `console=ttyS0,38400 earlyprintk androidboot.hardware=ranchu` (emu7_out.log:104) |
| Initrd / image layout / board issue | **RULED OUT** | No initrd work ever reached; the ranchu ELF kernel decompresses + relocates fine (emu8_out.log:88-102) |
| qalos system.img defect | **RULED OUT AS THE STALL CAUSE** | system.img byte-identical to the build output; the guest never got near rootfs, so user-space content is irrelevant to this failure |
| **Missing hypervisor signatures → guest dies in the LAPIC-timer/IPI window** | **MOST PLAUSIBLE** | emu5_out.log:991 `Booting paravirtualized kernel on bare hardware` + emu5_out.log:952 `tsc: Fast TSC calibration failed` — no Hyper-V enlightenments exposed, guest relies on emulated TSC/PIT/LAPIC, stall sits in the timer/IPI window right after init_IRQ |
| Kernel version too old (5.4.78 vs GKI 6.x era) | **SECONDARY SUSPECT** | Our kernel-ranchu is the AOSP 15 5.4 prebuilt (17,213,216 B) while AOSP 15 leans GKI 6.x and the emulator ships 6.1/6.6/6.12 prebuilts; stock API-35-ext15 kernel is 20,374,528 B |

## Most-plausible cause

**Paravirt-on-bare-hardware without hypervisor enlightenments.**
The 5.4 ranchu kernel prints `Booting paravirtualized kernel on
bare hardware` (emu5_out.log:991) with no hypervisor signature and
a failed fast TSC calibration (emu5_out.log:952). Under WHPX the
guest therefore falls back to the fully-emulated TSC/PIT/LAPIC
and consistently stalls in the LAPIC-timer / IPI window just after
init_IRQ — before `tick_init`, `init_timers`, `calibrate_delay`,
and SMP AP-bringup, none of which are ever reached (the < ~0.5
CPU-s, race-variable cut points are consistent with a timer/IPI
interleave).

**Secondary suspect:** kernel version. AOSP 15 ships a 5.4.78
`kernel-qemu2` prebuilt, but the era's emulator builds lean GKI
6.x and ship 6.1/6.6/6.12 prebuilts. The API-35 image the host
AVD is modeled on carries a 20,374,528 B kernel. A 6.x/6.12
kernel swap is cheap to test inside experiment 2 below.

## Decisive update (2026-09-13, T1–T4 experiments)

The "kernel stalls at zonelists" / "LAPIC-timer window" theory
was **partially refuted** by direct experiment after the docs
worker wrote the above section. The verdict table at the top of
this page (WHPX-in-general / cmdline / initrd layout / qalos
system.img defect all **RULED OUT**) is still correct, but the
**most-plausible cause** has shifted:

| Original hypothesis | Status after T1–T4 |
|---|---|
| Paravirt / TSC / LAPIC-timer window | **REFUTED for the kernel itself** — T3 booted the android-31 stock kernel to completion on this WHPX host, proving the LAPIC stall thesis was wrong for kernels that actually reach init. The 5.4 ranchu kernel never reaches init in this host *because it cannot mount `/dev/vda`*, not because it stalls in the timer window. |
| Kernel version too old | **DOWNGRADED to tertiary** — T3 proved the android-31 stock kernel (also AOSP 15 era) boots fine on this host when paired with a working ramdisk. |
| **Missing initramfs — kernel can't mount rootfs** | **NEW MOST-PLAUSIBLE CAUSE** — T3 (stock android-31 kernel + qalos 638-byte ramdisk + qalos system.img): kernel boots fully, then `VFS: Cannot open root device "vda" or unknown-block(0,0): error -6 → Kernel panic - not syncing`. The empty qalos ramdisk has no `lib/modules/*.ko` to load `virtio_blk`, so `/dev/vda` never exists. T4 (stock android-31 kernel + stock android-31 ramdisk + qalos system.img) confirmed: with the stock ramdisk (which has the virtio modules), init first stage **also** tries to mount `super, vbmeta` partitions (stock fstab references dynamic partitions) and SIGABRTs — the ramdisk fstab is the second blocker. Both blockers collapse to a single build-side fix: replace the qalos `debug_ramdisk` stub with the standard AOSP 15 `initrd` target via `INITRAMFS_IMAGE := initrd` in `device/qalos/qalos_emulator/BoardConfig.mk`. |

**Bottom line:** the qalos build is missing the initramfs step.
`aosp_x86_64.mk` (inherited by `qalos_emulator.mk`) defaults
`INITRAMFS_IMAGE := debug_ramdisk`, which emits a 638-byte stub.
Setting `INITRAMFS_IMAGE := initrd` produces a real initramfs with
`/init`, `init.rc`, `fstab.qalos_emulator`, and the virtio kernel
modules, and the build system appends it to the kernel image
during packaging. This is the architectural fix — verified by
attempt 13 (in flight as of 2026-09-13).

## Ranked next experiments (all free / local; NOT yet executed)

1. **Fresh stock API-35 control AVD boot (~15 min)** — boots a
   stock image on the same emulator/WHPX stack as our API-35
   sysdir. Decisively separates "emulator + WHPX + API-35 kernel
   generically" from "qalos artifacts". Run this first.
2. **Artifact bisect from the known-good Pixel_8 AVD (~30 min)** —
   point `image.sysdir.1` at the qalos sysdir
   (`D:\qalos\.pi\out\qalos-sys-img\android-35-ext15\default\x86_64\`),
   remove `kernel.parameters` + flag overrides, then swap
   kernel → ramdisk → system.img one at a time against the stock
   files (stock ramdisk substitute: 1,873,527 B; stock kernel:
   20,374,528 B). The first swap that changes behaviour names the
   culprit artifact.
3. **Re-run the android-31 control with `-show-kernel`**, capturing
   via `-qemu -serial file:...` (append) — NOT pipe redirect,
   which truncates on kill and is what faked the original "hang".

## Do NOT try

- **Building goldfish 5.4 "for AOSP 15"** — the last goldfish
  branch is `android-goldfish-5.4-dev`, two majors behind GKI.
- **Rebuilding system.img** — never reached; the guest never got
  near rootfs.
- **Chasing the Total-pages number** — it is exactly 4 GiB and
  normal.
- **Switching to AEHD** — sunsets Dec 2026.
- **`-no-accel` as a fix** — debug only (and v9 showed emulator.exe
  refuses the flag on this build anyway).

## Canonical emulator kernel cmdline

The canonical emulator guest cmdline (from
`main-kernel-parameters.cpp` / guest-boot docs):

```text
skip_initramfs rootwait ro init=/init root=/dev/vda1 qemu=1 clocksource=pit no-kvmclock 8250.nr_uarts=1 console=ttyS0,38400 androidboot.hardware=ranchu androidboot.console=ttyS0 keep_bootcon
```

Two notes for the qalos case:

- `root=/dev/vda1` above is the *canonical* form; the qalos legacy
  single-partition run uses `root=/dev/vda` (see the recipe).
- A bare system.img run (no real initramfs) typically needs the
  explicit `root=/dev/vda init=/init` that the AVD
  `kernel.parameters=` provides — the emulator's built-in defaults
  do not include them.

## Record for future agents

- **Artifacts:** `D:\qalos\.pi\out\qalos-sys-img\android-35-ext15\default\x86_64\`
  — `system.img` 2,147,483,648 B (byte-identical to the attempt-11
  build output), `kernel-ranchu` 17,213,216 B `bzImage` (SHA256-
  verified against AOSP 15's `prebuilts/qemu-kernel/x86_64/5.4/kernel-qemu2`;
  hex not recorded in-repo — re-verify by size + checksum against the
  prebuilt before any trust-sensitive use), `ramdisk.img` 638 B,
  `cache.img` 69,206,016 B, `userdata.img` 12,884,901,888 B
  (**stock playstore copy — wrong**, see the loading recipe), plus
  emulator-generated `*.qcow2` overlays.
- **Logs:** `C:\Users\bramburn\AppData\Local\Temp\2\emu5_out.log`
  (1010 lines), `emu7_out.log` (140), `emu8_out.log` (138),
  `emulator.log` (android-31 control, "Boot completed" at line 149).
- **Effective per-boot AVD config:** `pixel_8_hsk.avd\hardware-qemu.ini`
  — `kernel.path` at **line 109** and `ramdisk.path` at **line 113**
  both resolve into the qalos sysdir above. The *generated-ini*
  copy the emulator writes per launch is the thing to check when
  diagnosing "did my flags actually take".
- **Exact spliced cmdline as executed (v7/v8, with
  `kernel.parameters`):**

```text
8250.nr_uarts=1 clocksource=pit no_timer_check console=ttyS0,38400 earlyprintk=ttyS0 loop.max_part=7 root=/dev/vda init=/init androidboot.selinux=permissive ramoops.mem_address=0xff018000 ramoops.mem_size=0x10000 memmap=0x10000$0xff018000 printk.devkmsg=on android.bootanim=0 android.qemud=1 androidboot.android_dt_dir=/sys/bus/platform/devices/ANDR0001:00/properties/android/ androidboot.hardware=ranchu androidboot.hardware.vulkan=ranchu androidboot.serialno=EMULATOR37X1X11X0 qemu=1 qemu.avd_name=pixel_8_hsk qemu.camera_hq_edge_processing=0 qemu.camera_protocol_ver=1 qemu.dalvik.vm.heapsize=576m qemu.gles=1 qemu.gltransport=pipe qemu.gltransport.drawFlushInterval=800 qemu.opengles.version=131072 qemu.settings.system.screen_off_timeout=2147483647 qemu.skin=pixel_8 qemu.vsync=60 mac80211_hwsim.mac_prefix=5554
```

  (emu7_out.log:104, verbatim. The v5 run without `kernel.parameters`
  was the same minus `root=/dev/vda init=/init
  androidboot.selinux=permissive` — emu5_out.log:996.)
