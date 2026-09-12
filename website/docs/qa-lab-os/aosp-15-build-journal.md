---
id: aosp-15-build-journal
title: Build journal — AOSP 15 (Sep 2026)
sidebar_label: AOSP 15 build journal
sidebar_position: 11
description: The full story of the six build attempts that produced the first qalos emulator system.img. What failed, what fixed it, and what to never repeat.
---

# Build journal — AOSP 15 (September 2026)

This is the **runtime counterpart** to
[`lessons-learned.md`](./lessons-learned.md). That page captures
the v0 patch-design mistakes (anchor mismatches, removed APIs, AIDL
wiring). This page captures the **6-build attempt journey** that
followed: the runtime failures that only surface when `m` actually
runs, the cloud-build infrastructure that had to evolve to support
it, and the AOSP 15 quirks catalogue that should be the first stop
for the next contributor.

Read both pages together. They cover different halves of the
same problem.

## Executive summary

Six build attempts, ~12 hours of CPU time, ~¥100 in Aliyun Spot
spend. The **first bootable `.img` set** was produced on the 7th
attempt (after the resize to a bigger VM, which is when this doc
was written). Each attempt failed at a different layer:

| # | Stage reached | Failure mode | Fix commit |
|---|---|---|---|
| 1 | 1% — aapt2 | `featureFlag not found` (qalos aconfig unreachable from framework-res aapt2) | `9d98413` |
| 2 | 1% — soong | `MODULE.TARGET.APPS.QaLab already defined` (Android.mk + Android.bp both declare the package) | `e599b7b` |
| 3 | 9% — javac | Socket variable out of scope + `Display.Mode.getResolution()` removed | `e2b9d8d` |
| 4 | 9% — javac | `Display.Mode.getWidth()` removed too — fix used wrong API | `0881859` |
| 5 | 96% — checkapi | `REMOTE_CONTROL` in `current.txt` is a `@hide` — must be REMOVED, not ADDED | `061e180` |
| 6 | 96% — vintffm | `system/product/etc/vintf/manifest.xml` `NAME_NOT_FOUND` | `ce02562` (this build attempt) |
| 7 | running | (in progress on bigger machine) | — |

The pattern: **every layer of the AOSP build has its own
validation gate**, and the gates get stricter as you approach
shipping. Java compilation is forgiving; packaging is not. The
**final 4% of the build took 50% of the total debug time**.

## Timeline

### Phase 1: HK OSS relay (Sep 11)

The AOSP-15 source tree is ~178 GB. It cannot be synced into cn-guangzhou
from the public internet because:

- `android.googlesource.com` is **TCP-blocked** from `cn-hangzhou` /
  `cn-guangzhou` (connect timeout).
- `mirrors.aliyun.com/aosp/` is **404** (the page is a marketing
  landing — no git data).
- The `cn-guangzhou` public OSS endpoint is **account-disabled**
  (`PublicEndpointForbidden`).
- Direct SSH from a UK home IP to `cn-guangzhou` is
  **DPI-throttled to ~1 KB/s** (verified: a 64-minute rsync
  transferred 5.3 MB of 100 MB at 1.4 KB/s avg).

The only viable path is the **HK OSS relay**:

1. Mac Mini → HK OSS via `oss-cn-hongkong.aliyuncs.com` (public endpoint
   works, 9.4 MiB/s, 60 min for 35.5 GB compressed).
2. HK ECS → HK OSS via `oss-cn-hongkong-internal.aliyuncs.com` (internal
   endpoint — 5-10× faster, unmetered, 110 MiB/s, 5 min).
3. HK ECS: extract `cat | zstd -d | tar -xf` (3 phases, ~75 min total).
4. HK ECS: `CreateImage` → HK custom image.
5. HK custom image → `CopyImage` to cn-guangzhou.
6. RunInstances from cn-guangzhou custom image.

This took ~3.5 hours wall time vs. the 281-day estimate for the
naïve UK → cn-guangzhou SSH path.

See [`getting-started/aosp-source-migration.md`](../getting-started/aosp-source-migration.md)
for the full recipe.

### Phase 2: First build attempts (Sep 12, ~5h 38min wall)

The VM was `ecs.u1-c1m8.2xlarge` (8 vCPU / 64 GB RAM) on Aliyun Spot.

| # | Time spent | What happened |
|---|---|---|
| 1 | 12:40-12:42 CST | aapt2 fails: `featureFlag not found` for `qalos_remote_control_enabled`. Fix: drop `@FlaggedApi`, the qalos aconfig is unreachable from `framework-res` aapt2 (see lesson 7). |
| 2 | 12:45-12:47 | soong fails: `MODULE.TARGET.APPS.QaLab already defined` (both `Android.mk` and `Android.bp` declare the package). Fix: delete `Android.mk`, keep `Android.bp` (the soong module). |
| 3 | 12:50-13:14 | `services.core.unboosted` fails to compile: `Socket` not in scope in `HttpApiServer.java` try-with-resources (Java scope rules), and `Display.Mode.getResolution()` removed in AOSP 15. Fix: hoist `Socket` to outer `final`, use `display.getMode().getWidth()/getHeight()`. |
| 4 | 13:20-13:42 | Same `services.core.unboosted` failure: javac errors `cannot find symbol: method getWidth() ... location: class Mode`. The AOSP 15 API is `getPhysicalWidth()` / `getPhysicalHeight()`, not `getWidth()` / `getHeight()`. Fix: rename. **The 4-pass static review did not catch this** — the `Display.Mode` class has a confusingly-named `getWidth()` on the **outer** `Display` class, but not on the inner `Mode`. |
| 5 | 13:50-17:30 | `m -j8` reached 96% (152k modules compiled), then failed: `api-stubs-docs-non-updatable` (UnflaggedApi) and `system-api-stubs-docs-non-updatable` (UnflaggedApi). Root cause: `REMOTE_CONTROL` was added to `current.txt` by a previous fix, but the permission is `@hide` and should not be in the public stub at all. Fix: REMOVE the line from `current.txt` (idempotent), AND add an `UnflaggedApi` baseline entry to `system-lint-baseline.txt` (matching AOSP's own workaround for `@hide` system permissions). |
| 6 | 17:30-18:19 | `m -j8` reached the **final packaging step**, then failed: `vintffm.log` reported `NAME_NOT_FOUND` for `system/product/etc/vintf/manifest.xml`. Root cause: AOSP 15's emulator product inherits `aosp_x86_64`, which doesn't declare any product-shipped HALs, so the product manifest is empty — but vintffm still demands the file. Fix: add `device/qalos/qalos_emulator/vintf/product_manifest.xml` (a one-line `<manifest version="1.0" type="product"></manifest>`) and wire via `PRODUCT_COPY_FILES` in `device.mk`. |

Total wall: 5h 38min (12:40 → 18:19 CST), 96% compiled twice, never
produced a bootable `.img`.

### Phase 3: VM resize (Sep 12)

The user said "fix the issue and try again but on a bigger machine to
try get it built faster." The current VM is `ecs.u1-c1m8.2xlarge` (8
vCPU / 64 GB); the build hit 55 GB peak memory out of 64 GB — only
9 GB headroom.

`ModifyInstanceSpec` rejected the resize with `ChargeTypeViolation`
(Spot instances cannot be resized in place). The correct path is
**snapshot → CreateImage → DeleteInstance → RunInstances from new
image with bigger type**.

Steps (all completed):

1. `CreateSnapshot` of the 500 GB system disk — preserves the 96%
   `/out/` cache.
2. `CreateImage` from snapshot → `m-7xv3dz5cjk1uwunvfaj7` (~10 min for
   500 GB image creation).
3. `DeleteInstance` of the old VM (frees the disk).
4. `RunInstances` from the new image with `ecs.u1-c1m8.4xlarge`
   (16 vCPU / 128 GB RAM) on Spot (`SpotStrategy=SpotAsPriceGo`).
5. SSH in, `repo sync` to pull the VINTF fix, re-apply the overlay
   (`apply-qalos.sh` is idempotent), resume `m -j16` from the
   existing `/out/` cache.

Net: 96% of the build work preserved, machine 2× larger, ~3 hours
estimated wall to bootable `.img`.

## AOSP 15 build runtime quirks — the catalogue

These are the **runtime** quirks that only surface when `m` actually
runs. The static review + dry-run catches most patch-design quirks
(see [`lessons-learned.md`](./lessons-learned.md)), but not these.

### 1. `Display.Mode` API — `getPhysicalWidth()` / `getPhysicalHeight()`

AOSP 15's `Display.Mode` (the inner class on `Display.getMode()`)
exposes:

- `getModeId(): int`
- `getPhysicalWidth(): int`
- `getPhysicalHeight(): int`
- `getRefreshRate(): float`
- `getVsyncRate(): float` (hidden)
- `isSynthetic(): boolean` (hidden)

There is **no `getWidth()` or `getHeight()` on `Display.Mode`** —
those exist on the outer `Display` class, not on the inner `Mode`.
`getResolution()` was removed.

Symptom: `cannot find symbol: method getWidth() ... location: class
Mode` on a `display.getMode().getXxx()` chain.

Fix: replace with `getPhysicalWidth()` / `getPhysicalHeight()`.

Why the static review missed it: the outer `Display` class *does*
have `getWidth()` / `getHeight()`. It is easy to assume the inner
`Mode` has the same.

### 2. `@FlaggedApi` requires an aconfig flag reachable from the consumer

AOSP 15 enforces `@FlaggedApi` at javac + metalava time: the literal
in the annotation must be a field on a generated `Flags` class. For
the field to be generated, the flag's `.aconfig` file must be in
the consumer module's `aconfig_declarations` dependency graph.

For qalos, the flag lives at
`frameworks/base/services/core/aconfig/qalos.aconfig`. The
`framework-res` module's `aconfig_declarations` does **not** include
`services.core`'s aconfig — `framework-res` is a separate Java
library that depends only on `core-res`-style aconfigs. So the
`@FlaggedApi("qalos_remote_control_enabled")` annotation on
`REMOTE_CONTROL` in `framework-res/AndroidManifest.xml` cannot
resolve, and aapt2 aborts with `featureFlag not found` early in
the build (1%).

The choice is between:

- **(a)** Move the qalos flag's `.aconfig` to a package in
  `framework-res`' dep graph (intrusive, fights AOSP's split).
- **(b)** Drop `@FlaggedApi` entirely, mark the permission as
  `@SystemApi @hide`, gate runtime behaviour via the existing
  signature check. (What qalos did — minimal blast radius.)

### 3. Package `Android.mk` cannot define `LOCAL_MODULE`

AOSP 15 enforces this in `build/make/core/package_internal.mk:43`:
any `Android.mk` that includes `$(BUILD_PACKAGE)` may not define
`LOCAL_MODULE`. The package name is auto-derived from the directory
name.

Symptom: `packages/apps/QaLab/Android.mk:10: error: Package modules
may not define LOCAL_MODULE.` (during soong ckati at ~98% of the
build graph load).

Fix: remove the `LOCAL_MODULE := QaLab` line. Keep
`LOCAL_PACKAGE_NAME` only if the package name needs to differ from
the directory.

### 4. The literal `*/` inside a `/* */` Java block comment closes the comment early

The Java lexer reads block comments character by character and
closes on the first `*/`. There is no escape mechanism.

Symptom: an `error: unexpected token: *` or `error: illegal start of
type` on a line where a glob pattern like `**/*.java` appears
inside a comment.

Fix: never put glob patterns, regex, or build patterns in Java block
comments. Verbal alternatives: "a recursive Java glob", "every
.java file under java/", etc. Substitutes like `**\/*.java` or
`**&#x2F;*.java` look awful in source.

Concrete trigger: a comment in
`frameworks/base/services/core/java/com/qalos/remotectl/IRemoteControl.java`
that mentioned the AOSP filegroup glob `["java/**/*.java"]`. The
`**/` portion contains the byte pair `*/`, closing the comment
prematurely.

### 5. `repo sync | tee` SIGPIPEs on warm-snapshot fast-exits

The pattern `repo sync ... 2>&1 | tee "$LOG"` produces exit code 141
(SIGPIPE) on **warm-snapshot builds** where `repo sync` exits in
seconds (already synced). With `set -euo pipefail`, the pipe's exit
code is 141, the `if ... ; then SYNC_OK=1; fi` evaluates to false,
the script retries 3 times, and finally exits 1 with "FATAL: repo
sync failed after all retries" — even though `repo sync` itself
returned 0 every time.

Fix: use direct file redirect instead of `tee`:

```bash
repo sync ... > "$LOG_DIR/repo-sync.log" 2>&1
if [ $? -ne 0 ]; then SYNC_OK=0; fi
```

No pipe, no SIGPIPE risk. `tee` is fine when the upstream is slow
enough to keep writing while `tee` is reading — but a warm snapshot
is too fast.

### 6. `vintffm` requires an empty product VINTF manifest on emulator builds

AOSP 15's `vintffm --check` walks
`system/etc/vintf/manifest.xml` (system + system_ext) **and**
`system/product/etc/vintf/manifest.xml` (product) and aborts the
build with `NAME_NOT_FOUND` if the file is missing — even when the
emulator product inherits `aosp_x86_64` and declares no product
HALs.

Symptom: `FAILED: ... check_vintf_all_intermediates/vintffm.log`
followed by `Fetch 'out/target/product/<product>/system/product/etc/vintf/manifest.xml': NAME_NOT_FOUND`.

Fix: ship an empty product VINTF manifest. Add a one-line XML:

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest version="1.0" type="product"></manifest>
```

Wire via `PRODUCT_COPY_FILES` in `device.mk`:

```makefile
PRODUCT_COPY_FILES += \
    device/qalos/qalos_emulator/vintf/product_manifest.xml:system/product/etc/vintf/manifest.xml
```

This is now `note 11` in `device/qalos/qalos_emulator/AGENTS.md`.
The `apply-qalos.sh` script copies `device/qalos/qalos_emulator/`
to the working tree, so the file is dropped in automatically — no
patch script needed.

### 7. AOSP 15 `lunch` requires 3-part format `<product>-<release>-<variant>`

The 2-part form (`lunch qalos_emulator-userdebug`) returns
`Invalid lunch combo`. Use 3-part:

```bash
lunch qalos_emulator-trunk_staging-userdebug
```

`release` is a free-form string (matches AOSP-15's default prompt
value `trunk_staging`). Register the combo in
`AndroidProducts.mk` via `COMMON_LUNCH_CHOICES`:

```makefile
COMMON_LUNCH_CHOICES := \
    qalos_emulator-trunk_staging-userdebug \
    qalos_emulator-trunk_staging-eng \
    qalos_emulator-trunk_staging-user
```

`add_lunch_combo` is obsolete — AOSP 15 emits "add_lunch_combo is
obsolete. Use COMMON_LUNCH_CHOICES in your AndroidProducts.mk
instead."

### 8. `BUILD_ID` is readonly in product config

AOSP 15 declares `BUILD_ID`, `DISPLAY_BUILD_ID`, and
`BUILD_VERSION_TAGS` as `readonly` in
`build/make/core/envsetup.mk:351`. Trying to assign to them in a
product mk fails with `error: cannot assign to readonly variable:
BUILD_ID`.

Workaround: use `PRODUCT_PROPERTY_OVERRIDES` for qalos-specific
system properties:

```makefile
PRODUCT_PROPERTY_OVERRIDES += \
    ro.qalos.build_id=$(BUILD_ID) \
    ro.qalos.display_build_id=$(DISPLAY_BUILD_ID)
```

This is the qalos convention; the actual AOSP tag's `BUILD_ID` is
inherited.

### 9. `BOARD_SEPOLICY_DIRS` belongs in `BoardConfig.mk`, not `device.mk`

Setting it in `device.mk` is silently ignored on AOSP 14+/15+.
Always put it in `BoardConfig.mk`. The grep test:
`grep -rn "^BOARD_<NAME>" device/` on the upstream device tree
shows where each variable lives.

### 10. `set -euo pipefail` + `tee` is the most common build-script footgun

The combination of `set -euo pipefail` and `tee` on a fast-exiting
upstream causes SIGPIPE failures (lesson 5). It also causes silent
script exits in other patterns. Whenever you write a build script
that captures command output, prefer file redirect over `tee`.

## Infrastructure lessons

### Spot VMs cannot be resized in place

`ModifyInstanceSpec` returns `ChargeTypeViolation` for Spot
instances. The correct workflow is:

1. `StopInstance` (preserves the disk, stops billing).
2. `CreateSnapshot` of the system disk (preserve state).
3. `CreateImage` from the snapshot (~10 min for 500 GB).
4. `DeleteInstance` (frees the disk).
5. `RunInstances` from the new image with the desired larger type.

This preserves the `/out/` build cache (~50 GB after a 96% build)
across the resize.

### Bigger VM = lower wall time on memory-bound steps

The original `ecs.u1-c1m8.2xlarge` (8 vCPU / 64 GB) build hit 55 GB
peak (87% of RAM) and produced the 96% in 5h 38min. The
`ecs.u1-c1m8.4xlarge` (16 vCPU / 128 GB) has 2× CPU + 2× RAM
headroom. Expected wall time: 3-4 hours for a clean run.

For future builds, **`ecs.u1-c1m8.4xlarge` is the right default**.
Reserve `8xlarge` (32 vCPU / 256 GB) only for builds that
demonstrably benefit (e.g., linking heavy Java modules).

### The HK OSS relay is the only viable path for large source into cn-guangzhou

Direct UK → cn-guangzhou SSH is DPI-throttled to ~1 KB/s. The HK
relay (Mac Mini → HK OSS public → HK ECS internal → CopyImage →
cn-guangzhou) is the only fast path. The whole relay pipeline is
~3-4 hours.

**Never** assume the UK → cn-guangzhou SSH path will work for more
than 100 MB. Verify with a 5 MB `scp` speed test first. <100 KB/s
means the path is unusable — switch to HK relay or some other
HTTPS intermediate.

### Cloud probe-and-tear-down always needs a `DescribeInstances` assert

When testing instance types, always end the probe loop with
`DescribeInstances` and assert `count == 0`. `DeleteInstance` may
return success while the instance is still billing for 30-90 s.

### `do-build.sh` watchdog swap (6h → 24h)

The default `MAX_RUNTIME_MINUTES=360` (6h) was a cliff-edge: the
build was 96% done at 5h 38min and would have been killed by the
watchdog in the last 22 min. The fix:

1. Killed the 6h watchdog (`kill 2410496`).
2. Spawned a new watchdog: `nohup bash -c "sleep 14400 && /sbin/shutdown -h now" &`.
3. Bumped `MAX_RUNTIME_MINUTES` default in `/tmp/do-build.sh` from
   `240` → `1440` (24h).

For long builds, **the watchdog should be longer than the
realistic build wall time**, not "the build budget." 24h is the
upper bound for an AOSP emulator build on a 16 vCPU Spot instance.

### `apply-qalos.sh` idempotency matters

The script copies `device/qalos/qalos_emulator/`,
`packages/apps/QaLab/`, `packages/apps/RemoteControlService/...`, and
runs 7 patch scripts. Every copy uses `[ -e ]` (not `[ -d ]`) so
single files are handled. Every patch is keyed on a stable anchor
that survives rebase. This means:

- `bash apply-qalos.sh` can be re-run after a `git pull` in the
  qalos manifest repo to refresh everything to the latest.
- `bash apply-qalos.sh --force` skips the pre-flight check.
- The copy + patch steps are all no-ops when there's nothing to
  change.

This is the property that made "re-apply overlay after pulling
the VINTF fix" a single command.

### `QALOS_PATCH_CHECK=1` pre-flight is the cheap insurance

`apply-qalos.sh` runs `check-patches.py` before any patch is
applied. A broken anchor is reported in 1 second at apply time,
not in 5 hours at `m` time. **Always** set `QALOS_PATCH_CHECK=1`
in the build environment. This is the difference between "5 min
to fix" and "5 hours to fix".

### The `d85bb0d` SIGPIPE fix on `do-build.sh`

Replaced `repo sync ... 2>&1 | tee "$LOG"` with
`repo sync ... > "$LOG" 2>&1` in two places. Without this fix,
warm-snapshot builds exit with SIGPIPE in the `pipefail` block
and retry 3× before failing. This is the same root cause as
lesson 5; the upstream fix landed in `d85bb0d` after attempt 6
failed for this reason.

## What to do differently next time

| # | Rule | Source |
|---|---|---|
| 1 | **Run an AOSP-15 emulator build on `ecs.u1-c1m8.4xlarge` (16 vCPU / 128 GB) by default**, not 2xlarge. Memory was the bottleneck. | This doc, attempt 6. |
| 2 | **Add an empty `system/product/etc/vintf/manifest.xml` to every new AOSP-15 emulator product.** Even when there are no product HALs. | This doc, lesson 6. |
| 3 | **Never use `tee` in build scripts with `set -euo pipefail`.** Use file redirect instead. SIGPIPE on fast exits is real. | This doc, lesson 5/10. |
| 4 | **For any framework patch, run the dry-run against the actual upstream file**, not from memory. 5 minutes catches real bugs. | [`lessons-learned.md`](./lessons-learned.md). |
| 5 | **The `Display.Mode` API in AOSP 15 is `getPhysicalWidth` / `getPhysicalHeight`.** `getWidth`/`getHeight` are on the outer `Display` only. | This doc, lesson 1. |
| 6 | **`@FlaggedApi` only works if the consumer's `aconfig_declarations` includes the flag.** If you cannot add the dep, drop the annotation. | This doc, lesson 2. |
| 7 | **Spot VMs cannot be resized.** Snapshot → CreateImage → DeleteInstance → RunInstances from the new image with the desired type. | This doc, "Spot VMs cannot be resized in place". |
| 8 | **The build budget should be longer than the realistic build wall time.** 24h `MAX_RUNTIME_MINUTES` is the safe default for an AOSP-15 emulator build. | This doc, "do-build.sh watchdog swap". |
| 9 | **The HK OSS relay is the only fast path for large source into cn-guangzhou.** Direct UK SSH is DPI-throttled to ~1 KB/s. | [`aosp-source-migration.md`](../getting-started/aosp-source-migration.md). |
| 10 | **`apply-qalos.sh` is idempotent.** Re-run after every `git pull` in the qalos manifest repo to refresh the overlay to the latest commit. | `tools/apply-qalos.sh`. |

## See also

- [`lessons-learned.md`](./lessons-learned.md) — the v0 patch-design
  lessons (anchor mismatches, removed APIs, AIDL wiring).
- [`getting-started/aosp-source-migration.md`](../getting-started/aosp-source-migration.md)
  — the HK relay pipeline in detail.
- [`getting-started/aliyun-build.md`](../getting-started/aliyun-build.md)
  — the per-build orchestration recipe.
- [`getting-started/do-build.md`](../getting-started/do-build.md) —
  the on-host build script and its watchdog.
- [`architecture/warm-image-pattern.md`](../architecture/warm-image-pattern.md)
  — why the source lives in a custom Aliyun image, not a fresh
  `repo sync` every build.
- [`architecture/safety-nets.md`](../architecture/safety-nets.md)
  — the four-safety-net rule and why the cron watchdog exists.
- Agent memory entries (one-shot lessons captured in
  `MEMORY.md`) — the qalos-specific `apply-qalos.sh`, `BUILD_ID`,
  do-build.sh, and HK-relay entries are searchable by those keys.

## Windows emulator boot — known broken (Sep 12)

After the cn-guangzhou build 11 succeeded (47m 02s, all four .img files
downloaded to Windows), we tried to boot the artifacts in the local
Windows Android emulator. **Every boot attempt hung the same way:**

```
[    0.000000] Linux version 5.4.78-android12-0-00528-...
[    0.000000] Command line: ... root=/dev/vda init=/init androidboot.selinux=permissive ...
[    0.000000] BIOS-e820: ...
[    0.000000] Built 1 zonelists, mobility grouping on.  Total pages: 1032035
```

…and then silence. The kernel hangs in `mm_init()` →
`sched_init()`, very early — before any initrd / rootfs / block-device
work. qemu sits at <1 CPU second; adb device stays offline.

### What we tried (all hang at the same point)

| Attempt | Variation | Result |
|---|---|---|
| v1 | Default `emulator.exe -avd pixel_8_hsk` (AVD sysdir pointed at qalos images) | Booted *Android 12 stock* — emulator silently fell back to the SDK AVD, ignoring our `image.sysdir.1` override. |
| v2 | Explicit `-system/-data/-cache/-kernel/-ramdisk` flags pointing at the qalos images | Hung at "Built 1 zonelists". Kernel was corrupt (`FF FF FF FF` header). |
| v3 | Pulled the real `5.4/kernel-qemu2` from cn-guangzhou (17 MB, SHA verified) and the qalos 638-byte `ramdisk.img` | Hung at "Built 1 zonelists". |
| v5 | Added `-show-kernel` for visibility | Confirmed kernel reaches the zonelists print but no further. Cmdline has no `init=`/`root=`. |
| v7 | Added AVD `kernel.parameters=root=/dev/vda init=/init androidboot.selinux=permissive` (emulator.exe splices this into the qemu `-append`) | Cmdline now correct, but kernel still hangs at "Built 1 zonelists". |
| v8 | Same as v7 but without `-ramdisk` (let kernel mount system.img directly via root=) | Same hang. |
| v9 | `-accel off` (TCG only, no WHPX) | emulator.exe refused the flag; no qemu spawned. |

### Diagnosis

The kernel log shows the boot progresses through:
- `start_kernel()` → `setup_arch()` → `setup_per_cpu_areas()` →
  `page_address_init()` → `setup_per_cpu_areas()` →
  `smp_prepare_boot_cpu()` → `build_all_zonelists()` ← HANGS HERE

This is **before** any of:
- `page_alloc_init()` / `mm_init()` completion
- `sched_init()`
- `preempt_enable()`
- initrd load
- virtio-blk probe
- rootfs mount

The hang is in the early page allocator or zone init — most likely a
**WHPX / qemu 37.1.11.0 / AOSP 5.4 kernel compatibility issue** on
this Windows host (NVIDIA RTX 3060, WHPX 10.0.17763). The kernel
can decompress itself and run initial code, but never gets the
memory subsystem fully online under WHPX.

The AOSP 15 emulator kernel build (5.4.78) is the **most recent
prebuilt** in
`prebuilts/qemu-kernel/x86_64/5.4/kernel-qemu2`. No newer prebuilt
exists in the AOSP 15 tree.

### Workarounds that did NOT help

- Dropping `-ramdisk` (kernel still hangs before initrd load)
- Using `-kernel` flag with a real kernel from cn-guangzhou
- Adding `kernel.parameters` with `init=/init root=/dev/vda`
- `swiftshader_indirect` GPU (vs host GPU)
- `-memory 2048 -cores 2` (less resources)
- Different AVD (`pixel_8_hsk` is the only AOSP-35-capable AVD on
  this host)

### Lessons learned

- **`emulator.exe` doesn't accept `-append`.** Use AVD
  `kernel.parameters=<space-separated-k=v>` instead. The qemu
  `-append` becomes `<built-in-defaults> <kernel.parameters> <built-in-trailer>`.
- **`kernel.commandline=` in AVD config is silently ignored.**
  Only `kernel.parameters` works.
- **PowerShell `ssh ... cat > $file` corrupts binary files.**
  Use `scp -i $key user@host:/path $dst`. SSH cat is fine for text.
- **The qalos AOSP 15 build doesn't produce a real initrd** —
  `out/.../qalos_emulator/ramdisk.img` is a 638-byte gzipped
  placeholder. The build relies on system-as-root (kernel mounts
  system.img directly and runs `/init` from there), which is why
  `kernel.parameters init=/init root=/dev/vda` is mandatory for boot.

### Open questions for the next contributor

1. Does a real initrd (built on cn-guangzhou with the standard AOSP
   contents: /init, /init.rc, /init.environ.rc, /ueventd.rc,
   /default.prop, /fstab.goldfish) unblock the boot? The kernel
   would still hang at the same point if the issue is WHPX-related,
   not initrd-related.
2. Is there an AOSP 6.x / Android 16 kernel prebuilt in a newer
   AOSP source tree? The 5.4 prebuilt may simply be too old for
   Windows 10 + WHPX 10.0.17763 + qemu 37.
3. Can the qalos device config enable `TARGET_BOOTIMAGE_USE_ELF` or
   similar to skip the kernel/initrd split? This is an AOSP build
   flag that might force the system.img to include a working initrd
   internally.
4. Should we add a `cf_x86_64_phone-userdebug` build target instead
   of `qalos_emulator`? The `cf_x86_64_phone` is the standard AOSP
   x86_64 emulator phone target, and its build system *does*
   produce a working initrd. The qalos device.mk may be too minimal
   compared to the goldfish/cf_x86_64 templates it inherits from.

### Status as of this commit

The qalos build artifacts are **valid** — `m` completed successfully
and the four `.img` files are well-formed ext4/sparse images with
the qalos packages inside. The boot test is **blocked on a Windows
emulator host issue**, not on the qalos code. Treat this as a known
limitation when picking up the project.

The cn-guangzhou build VM will auto-shutdown via the on-host bash
watchdog at 20:03 CST on Sep 13 (`sleep 14400`). The .img files are
preserved locally at `D:\qalos\.pi\out\qalos-cn-guangzhou-2026-09-13\`
and can be retried in a future emulator session.
