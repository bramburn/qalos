# LESSONS — Pixel 7 Pro (cheetah) AOSP build

> **READ THIS BEFORE SPENDING ANY MONEY.** Every entry is a mistake that
> was actually made on this project, with the symptom it produced and
> the fix that worked. Companion to [`AGENTS.md`](AGENTS.md) (the
> workflow); AOSP API-level detail is in
> [`../aosp-15-api-notes.md`](../aosp-15-api-notes.md).
>
> Proven/corrected 2026-09-28 (b13 failed, b14 passed, $4.36 total).

---

## 0. The five that matter most

| # | Trap | Cost of getting it wrong |
|---|---|---|
| 1 | Staging a compressed tree to the build host | 95+ min of pointless compression, then abandoned |
| 2 | Trusting `m` exit 0 as "qalos is in the image" | A build that silently shipped **stock AOSP** (2026-09-11) |
| 3 | Guessing AOSP APIs from memory | 5 fixes written, 5 walked back |
| 4 | Destroying the VM on build failure | Threw away a 179 GB sync (32 min / ~$0.30) to fix one line |
| 5 | A patch that lies about being applied | Build failed at 98% on a gate the patch claimed to satisfy |

---

## 1. Never compress-and-transfer a `repo` checkout

**What was tried.** macmini2024 had a 181 GB AOSP tree. Plan: `tar | zstd`
it, scp to the GCP VM, untar there.

**Why it fails, measured.** Most of the bytes are *already compressed*:

| Part | Share of 181 GB | Compression ratio measured |
|---|---|---|
| `.repo/project-objects` | 84 GB | **1.011:1** (already zlib) |
| `prebuilts` | 56 GB | 3.21:1 |
| source | remainder | 4.90:1 |

You cannot beat 1:1 by raising the zstd level. 84 of the 181 GB is
uncompressible, so no zstd setting helps. The fix would be *excluding*
`.repo/project-objects` — a config change, not a compression knob — and
you would still pay full transfer time for a tree the destination can
fetch for free in parallel.

**Compounding factor.** macmini2024's root volume is a **spinning disk**
(`sda`, `ROTA=1`). A single large `tar` degrades sharply on the
small-file tail, so wall time is dominated by the *last* GB. The run was
measured at ~1.5 MB/s and had produced 33 GB of archive in 95+ minutes
when it was killed.

**The fix: let the build host sync itself.**

| | Time | Notes |
|---|---|---|
| compress 33 GB on macmini + transfer + untar | 95+ min (abandoned at 33/181 GB) | rotating disk, already-compressed payload |
| `repo sync` directly on the GCP VM | **~32 min** for 175-179 GB | bandwidth-bound, parallel |

The source host drops out of the pipeline entirely. macmini2024 is now
only an image-drop destination and the flashing host.

---

## 2. Read the tree before fixing AOSP. Every time

Five fixes on this project were written from memory. All five were
wrong and had to be reverted.

| Guess | Reality | Where the truth is |
|---|---|---|
| `-c3-highmem-32` machine type | C3 only has `-4/-8/-22/-44/-88` | `gcloud compute machine-types list` |
| `release_config_map.textproto` | **No device tree in AOSP 15 ships one** — no precedent, no reference implementation | `build/release/` |
| Pin `TARGET_RELEASE` in the product makefile | All `RELEASE_*` flags are **readonly** in product config | `build/make/core/product_config.mk:234` |
| 3-argument `lunch` | AOSP 15 takes **exactly one** argument, split on `-`. The 3-part form is AOSP 16 | `build/envsetup.sh:442` |
| `LocalServices.get(...)` | The accessor is `getService(Class)` | `frameworks/base/services/core/java/com/android/server/LocalServices.java` |

Full detail: [`../aosp-15-api-notes.md`](../aosp-15-api-notes.md).

**Rule:** when an AOSP build error appears, read the actual source in
the synced tree and quote the file and line. Do not write a fix from
recall. If the fix does not apply, the error text names the real
constraint.

---

## 3. The 98% failure: a patch that reported success while doing nothing

**Symptom.** `qalos-b13` reached 98% (136,034/138,691) and exited 1:

```text
out/srcjars/android/Manifest.java:6769: error: New API must be flagged with
@FlaggedApi: field android.Manifest.permission.REMOTE_CONTROL [UnflaggedApi]
```

All the `.img` files existed on disk. `m` had produced flashable-looking
output and still returned failure.

**Root cause.** Patch
`packages/apps/RemoteControlService/patches/0005-*.py` exists to
annotate our signature permission as `@SystemApi @hide` in
`AndroidManifest.xml` — exactly what metalava requires. Its log line
said:

```text
[0005] already applied (idempotent skip)
```

The manifest had **no `@hide` anywhere near the permission**. The patch
had never once done its job.

The idempotency check was:

```python
m = re.search(r"<!-- @SystemApi @hide[\s\S]*?REMOTE_CONTROL[\s\S]*?/>", text)
```

`[\s\S]*?` is unbounded, so it scans the **whole 9,000-line** AOSP
manifest. An unrelated `@SystemApi @hide` comment hundreds of lines
earlier satisfies the left half; our permission satisfies the right half.
Match found → "already applied" → exit 0 → nothing edited. There are
243 other `@hide` comments in that file for it to trip over.

**The fix** (in `0005-*.py`): replace the spanning regex with an exact
block test, which cannot lie and cannot span.

```python
if NEW_BLOCK in text:
    print("[0005] already applied (idempotent skip)")
    return 0
```

**How it was verified.** A fixture manifest was built containing a
**decoy** `<!-- @SystemApi @hide -->` comment *plus* an un-annotated
REMOTE_CONTROL block. The old logic skips (wrong). The fixed logic
annotates on run 1 and idempotently skips on run 2. Run that fixture
test before trusting any change to a patch's idempotency check.

**Lesson.** A patch's "already applied" is a claim, not a fact. When a
build fails on something a patch claims to handle, **verify the tree
directly** before believing the patch ran.

---

## 4. The metalava permission gate (and why a self-heal could not save it)

A new `<permission>` in `frameworks/base/core/res/AndroidManifest.xml`
is new public API surface. AOSP 15's metalava rejects it unless the
permission is either in `core/api/current.txt` or marked `@hide`.

**The working solution** is the convention AOSP itself uses — a `@hide`
marker in the XML comment immediately above the element:

```xml
<!-- @SystemApi @hide
     qalos: signature permission that gates RemoteControlService. -->
<permission android:name="android.permission.REMOTE_CONTROL"
    android:label="@string/permlab_remoteControl"
    android:description="@string/permdesc_remoteControl"
    android:protectionLevel="signature" />
```

**Evidence this is the right convention**, from the same file (there are
243 `@hide -->` blocks in it):

| Permission | `@hide` comment? | In `core/api/current.txt` |
|---|---|---|
| `TV_VIRTUAL_REMOTE_CONTROLLER` | yes | **0** |
| `CHANGE_HDMI_CEC_ACTIVE_SOURCE` | yes | **0** |
| `ACCESS_NETWORK_STATE` | no | **4** (present) |
| `DUMP` | no | **1** (present) |

**`@FlaggedApi` is not available here.** An earlier attempt used
`@FlaggedApi("com.qalos.flags.remote_control")` plus
`android:featureFlag=...`. Metalava accepted it; **aapt2** then failed:

```text
error: attribute 'android:featureFlag' has flag 'com.qalos.flags.remote_control'
not found in flags from --feature_flags parameter
```

aapt2's flag list is populated from the `aconfig_declarations` that are
transitive deps of `framework-res`. The qalos aconfig lives in
`services.core`, which is not in the framework-res graph, so the flag
never reaches aapt2. Getting a feature flag to work here would mean
moving the aconfig into a library declared in
`frameworks/base/core/res/Android.bp`'s `flags_packages`.

**The self-heal that did not work.** `gcp_cheetah_build.sh` had a retry
that ran:

```bash
m -j$(nproc) api-stubs-docs-non-updatable-update-current-api
```

That is **not a real target**. It failed with `exit status 255`, and
attempt 2 failed identically. Metalava's own error text gives the real
remedy (copy `api_lint_baseline.txt` over
`core/api/lint-baseline.txt`), but suppressing the lint is the wrong
lever anyway — `@hide` fixes the *surface*, which is what both
`UnflaggedApi` and `check_current_api` were complaining about. **A
baseline edit silences one and not the other.** If you retry this path,
delete the self-heal rather than trusting it.

---

## 5. Verification gates that lie

Three checks in this project produced a *wrong verdict*. Each was
written by me, not inherited.

| Check | Looks right | Actually | Correct gate |
|---|---|---|---|
| `grep -c qalos frameworks/base/core/api/current.txt` | "no qalos in API" | 0 is **expected** — the permission is `@hide` | drop it; gate on the image contents |
| `grep -c 'UnflaggedApi' bNN.log` | "lint error present" | 1 on a **clean** build: it matches patch 0008's *filename* in `[apply-qalos] status=ok patch=0008-...-UnflaggedApi-...py` | `grep -c 'UnflaggedApi]'` (closing bracket) |
| `find .../system/framework/services.core.unboosted.jar` | "jar missing → overlay missing" | in `userdebug` builds that jar is not the one shipped | `services.core.jar`, or gate on the image itself |

**Rule:** before reporting a build good or bad, confirm the gate
measures the thing it claims to. A gate that cannot distinguish success
from failure is worse than no gate, because it manufactures confidence.

---

## 6. Never destroy the build host on a failure

The monitor was originally written to delete the instance when the build
"definitively failed". On b13 that would have discarded a **179 GB**
`repo sync` (32 minutes, ~$0.30) to recover from a one-line XML comment.

The teardown rule's own condition is "only after images are verified
out" — they were not. A build failure is a diagnose-patch-relaunch
event; an incremental ninja run over a warm tree took **37 minutes**
(6,618 edges) versus 98 minutes cold for the original 138,691.

**Keep the host until the images are out and byte-verified.**

### 6a. And: pull the logs *before* you delete it

Done correctly on images, done wrong on logs. The instance was deleted
with `b13.log` and `b14.log` still sitting in `/home/bramburn/`, so the
complete build record — every patch status line, the metalava error in
full, the ninja progress — was destroyed with the VM and is now
unrecoverable without a full rebuild.

**The deliverable is the images *and* the evidence.** A build you cannot
explain afterwards is a build you have to re-run to understand.

```powershell
# BEFORE gcloud compute instances delete
& $scp -i $key -r 'bramburn@<ip>:/home/bramburn/*.log' 'D:\qalos\.pi\build-logs\'
& $scp -i $key -r 'bramburn@<ip>:/home/bramburn/*.sh' 'D:\qalos\.pi\build-logs\'
```

**Pre-deletes checklist:** images MD5-verified everywhere · `*.log` and
the build driver `*.sh` pulled · GCS copy confirmed. If the VM is
already gone, say the logs are lost — do not reconstruct them from
memory or from chat excerpts.

---

## 7. Windows operator traps (this host)

| Trap | Symptom | Do this |
|---|---|---|
| `$(...)` inside a double-quoted PowerShell argument | PowerShell evaluates it locally; remote command breaks | use single quotes, or write a script file and `scp` it |
| Windows OpenSSH strips double quotes from the remote command | mangled `printf`/`for` loops | script file + `bash /tmp/x.sh` |
| `Remove-Item` | policy-blocked | `mavis-trash` |
| `gcloud compute ssh` | Plink handshake failure | `C:\Windows\System32\OpenSSH\ssh.exe` directly |
| `pkill -f <pattern>` | kills the SSH session running it | `pkill -x` |
| `Set-Content -Encoding UTF8` | injects a BOM into commit messages | `[System.IO.File]::WriteAllText($p,$t,(New-Object System.Text.UTF8Encoding($false)))` |
| `$(...)` in a remote heredoc | silently empty output | ship the script as a file |

---

## 8. Open blocker: no `vendor.img`, no `super.img`

**This is the most important thing in this file.** The build is
complete and correct, and the images are *not* flashable to a stock
Pixel 7 Pro as they stand.

Observed on the successful b14 build:

- `vendor/` staging: **6.4 MB, 47 files**, all generic AOSP
  (`libbinder`, `libcutils`, `libc++`, `libdmabufheap`) — **no Google
  vendor blobs**, as expected from the blob-less design
  (`inherit-product-if-exists` makes the blob makefiles optional).

- **No `vendor.img` produced.**

- **No `super.img` produced.** `super_empty.img` (4,976 bytes) exists
  as a placeholder only.

- `PRODUCT_NAME := aosp_cheetah`, `PRODUCT_DEVICE := cheetah`.

A stock Pixel 7 Pro (cheetah) ships with **virtual-A/B dynamic
partitions**: system/product/system_ext/vendor live inside a single
`super` partition, and those physical partitions do not exist to flash
individually. A build emitting standalone `system.img`/`product.img`/
`system_ext.img` with no `super.img` and no `vendor.img` does not match
that layout, and there is no vendor image to satisfy the stock vendor
partition's HALs. Flashing as-is is likely to fail or boot-loop.

**To flash real hardware, one of these is needed first:**

1. A device tree that matches cheetah's **actual dynamic-partition
   layout**, plus the Google **vendor blobs** — i.e. drop the
   `inherit-product-if-exists` optionality and source the driver zips
   described in `device/google/cheetah/README.md`. Different build, not
   a different flash command.

2. Build with `PRODUCT_USE_DYNAMIC_PARTITIONS := true` and a
   `BOARD_SUPER_PARTITION_GROUP_LIST` matching the device, producing a
   real `super.img` via `lpmake`.

3. Test on the **emulator** target (`qalos_emulator-userdebug`), which
   is the first-class target in the root `AGENTS.md` and exercises
   RemoteControlService end to end without any of this.

Do not attempt a flash on option (a) hardware until the partition
layout question is settled.
