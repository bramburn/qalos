# qalos GCP build runbook — Pixel 7 Pro (cheetah)

> **The LLM-driven GCP runbook.** An agent building the cheetah product
> on a GCP Spot instance reads this file **first**, in this order:
> [`LESSONS.md`](LESSONS.md) (the traps — read before you spend money),
> then the workflow below.
>
> Proven end to end on 2026-09-28: 179 GB `repo sync` + full `m` +
> verified image delivery for **$4.36**.

Sibling runbooks: [`../aliyun/AGENTS.md`](../aliyun/AGENTS.md) (the
template this one follows), `../AGENTS.md` (the `tools/` index).

---

## 0. Non-negotiables

Read these as hard rules, not advice. Each one exists because the
opposite was tried and cost real time or money.

1. **Never trust `m` exit code 0.** On 2026-09-11 a build exited 0 and
   produced images byte-identical to stock Pixel_8 Android 35, because
   `apply-qalos.sh` had never landed. Verify *inside* the image (§5).

2. **Never stage a compressed tree to the build host.** Let the build
   host `repo sync` itself. Measured 32 min direct vs 95+ min to
   compress 33 GB on a spinning disk. See [`LESSONS.md`](LESSONS.md) §1.

3. **Never destroy the instance on a build failure.** It holds the
   179 GB sync. A re-sync costs ~32 min and ~$0.30; re-doing a
   one-line source fix costs seconds. Teardown happens only after the
   images are delivered **and** byte-verified (§6).

4. **Never use `gcloud compute ssh`.** The gcloud SDK hardcodes PuTTY
   /Plink, which fails against modern Linux OpenSSH. Use
   `C:\Windows\System32\OpenSSH\ssh.exe` directly.

5. **Never use `tools/gcp-build.ps1` for a long build.** It has a 4-hour
   SSH-shutdown bug that deletes a healthy build. See `../AGENTS.md`.

6. **Read the tree, not your memory, before fixing AOSP.** Five
   separate fixes on this project were guessed from memory and all five
   had to be walked back. See [`LESSONS.md`](LESSONS.md) §2.

---

## 1. Instance shape that works

| Property | Value | Why |
|---|---|---|
| Machine type | `n2-highmem-32` (32 vCPU / 256 GB) | 256 GB avoids OOM on an arm64 AOSP build |
| Provisioning | **SPOT** | ~5x cheaper than on-demand; a reclaim mid-build is recoverable |
| Disk | 500 GB `pd-standard` | `pd-ssd` is unnecessary; the build is I/O-light on 179 GB |
| Zone | `europe-west2-b` (London) | Close to the user; GCS bucket is same-region |
| Project | `crypto-galaxy-846` | |

**Do not switch region/machine type mid-build.** Switching discards the
sync for ~$1-2 of total compute. Stay put.

**Cost shape:** `n2-highmem-32` SPOT ~$0.53/hr + `pd-standard` 500 GB
~$0.030/hr = **$0.56/hr blended**. The 179 GB inbound `repo sync` is
**free** (inbound is never billed). Put the GCS bucket in the *same*
region so uploads are free too.

---

## 2. Transport

```powershell
$ssh = 'C:\Windows\System32\OpenSSH\ssh.exe'
$key = "$env:USERPROFILE\.ssh\google_compute_engine"
& $ssh -i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new bramburn@34.105.204.203 '<cmd>'
```

> **Windows OpenSSH quoting trap.** PowerShell evaluates `$(...)` inside
> double-quoted arguments, and Windows OpenSSH strips double quotes from
> the remote command line. Any remote command with `$(...)`, nested
> quotes, or a `for` loop will be mangled. **Write a script file, `scp`
> it, then `bash /tmp/x.sh`.** Every script used on this path was done
> that way. It is the only reliable pattern from PowerShell 5.1.

---

## 3. Build driver

The build runs as a **transient systemd unit**, not over an SSH
session. A session dies; a unit survives and keeps a log.

```bash
sudo systemd-run --unit=qalos-bNN \
  --property=StandardOutput=append:/home/bramburn/bNN.log \
  --property=StandardError=append:/home/bramburn/bNN.log \
  --setenv=HOME=/home/bramburn \
  --setenv=XDG_CACHE_HOME=/home/bramburn/.cache \
  /bin/bash /home/bramburn/gcp_cheetah_build.sh
```

Number the units (`b13`, `b14`, ...). One unit per attempt: the log
file is the attempt record, and the previous unit's log is what you
read when diagnosing a failure.

### 3.1 The build script's required shape

```bash
#!/bin/bash
# NO `set -u`. build/envsetup.sh:21 reads $TOP before assigning it, so
# nounset kills the whole build with "line 21: TOP: unbound variable"
# and `lunch` is never even defined.
set -o pipefail
export HOME=/home/bramburn XDG_CACHE_HOME=/home/bramburn/.cache
```

Order of operations inside the script:

1. `cd .repo/manifests && git clean -fdx` then check out
   `feat/qa-lab-os-v1` and `chmod +x tools/`. Without the `git clean`,
   leftover files from `apply-qalos.sh` block the branch switch.

2. `apply-qalos.sh` — copies the qalos overlay in, runs patches 0002-0010.

3. `fix-aosp-15-issues.sh` — the two upstream AOSP 15 metalava fixes
   (see [`../aosp-15-fixes.md`](../aosp-15-fixes.md)).

4. **Kernel stand-in** (see §3.2).

5. `lunch qalos_cheetah-trunk_staging-userdebug`.

6. Soong bootstrap, then `m -j$(nproc)`.

7. Artifact listing.

### 3.2 The kernel stand-in — remove once real 6.1 prebuilts exist

`build/release/flag_values/trunk_staging/` defines
`RELEASE_KERNEL_CHEETAH_DIR` pointing at `6.1/trunk-11970169`, but
`repo sync` only brings down `5.10/24Q3-12115410`. The `RELEASE_*`
flags are **read-only** in product config, so you cannot redirect the
release flag. Instead create an absolute symlink:

```bash
ln -sfn /home/bramburn/aosp/device/google/pantah-kernels/5.10/24Q3-12115410 \
        /home/bramburn/aosp/device/google/pantah-kernels/6.1/trunk-11970169
ls -L /home/bramburn/aosp/device/google/pantah-kernels/6.1/trunk-11970169/Image.lz4
```

The `ls -L` (follow) is the verification. The target **must be
absolute** — a relative symlink resolves against the symlink's own
directory and points nowhere.

> This is a stand-in, not a fix. The 5.10 kernel is being used where the
> release config wants 6.1. Delete this step when genuine 6.1 prebuilts
> are synced.

### 3.3 Passing the release to `m`

`lunch` exports the target into its own sub-make only. For a third-party
product in a fresh `envsetup` pass, export it yourself before `m`:

```bash
export TARGET_PRODUCT=qalos_cheetah
export TARGET_RELEASE=trunk_staging
export TARGET_BUILD_VARIANT=userdebug
m -j$(nproc)
```

---

## 4. Sync and the integrity gate

```bash
repo init -u https://github.com/bramburn/qalos -b main
repo sync -c -j8 --no-tags --no-clone-bundle
```

**`-j8`, not `-j16`/`-j32`.** The git fetches hit `android.googlesource.com`,
which rate-limits per IP; higher concurrency returns HTTP 429 on a
handful of the ~1400 repos. `-j8` finishes in about the same wall time
because the fetches are bandwidth-bound, not CPU-bound.

**Gate before building.** A partial sync produces a build that fails
hours later in a confusing place:

```bash
wc -l .repo/project.list          # must be 1423
# every listed project must have a .git
```

Only proceed to the build when the project count is 1423 and no project
is missing its `.git`.

---

## 5. Verify the images — the part that cannot be skipped

A clean `m` exit proves the compiler was happy. It does **not** prove
qalos is in the image. This is the 2026-09-11 failure, and it is why
these four checks are mandatory before delivery.

```bash
P=/home/bramburn/aosp/out/target/product/qalos_cheetah

# 1. build log is clean
grep -c 'error:'      /home/bramburn/bNN.log   # 0
grep -c 'FAILED:'     /home/bramburn/bNN.log   # 0
grep -c 'UnflaggedApi]' /home/bramburn/bNN.log # 0

# 2. our classes are compiled into services.core
unzip -l "$P/system/framework/services.jar" | grep -c 'com/qalos/'      # > 0

# 3. our app shipped
find "$P" -name 'QaLab.apk'                                            # exists

# 4. THE DECISIVE ONE - the code is inside the flashable image
strings -a "$P/system.img" | grep -cE 'com/qalos/remotectl'            # > 0
strings -a "$P/system.img" | grep -c 'REMOTE_CONTROL'                  # > 0
```

Check 4 is the one that would have caught the v11 stock-image build.
Confirming the fingerprint is a good secondary signal:

```text
ro.system.build.fingerprint=qalos/qalos_cheetah/qalos_cheetah:VanillaIceCream/AP3A.240905.015.A2/...:userdebug/test-keys
```

> **Gates that lie — avoid these.**
> - `grep -c qalos frameworks/base/core/api/current.txt` returns 0 on a
>   **good** build. The permission is `@hide` so it is not public API.
>   Treating 0 as a failure is wrong.
> - `grep -c 'UnflaggedApi'` (bare) returns 1 on a **good** build, because
>   it matches patch 0008's *filename* in the apply-qalos status line.
>   Only `UnflaggedApi]` is a real error.
> - The API text files live at `frameworks/base/core/api/`, not
>   `frameworks/base/api/`.

---

## 6. Deliver, verify, then tear down

```powershell
# a) to this machine
& $scp -i $key 'bramburn@34.105.204.203:/home/bramburn/aosp/out/target/product/qalos_cheetah/*.img' `
        'D:\qalos\.pi\out\cheetah\'
#    super_empty.img is mode 0600 root and will be refused - it is a 4,976-byte
#    build placeholder, not a flashable. Harmless.

# b) to GCS (durable, survives VM deletion). Windows -> GCS is free.
gcloud storage cp --recursive 'D:\qalos\.pi\out\cheetah' 'gs://qalos-aosp-eu/images/cheetah' --project=crypto-galaxy-846

# c) to macmini2024 (the flashing host)
& $ssh -i "$env:USERPROFILE\.ssh\id_ed25519_qalos" bramburn@192.168.0.46 'mkdir -p /home/bramburn/qalos_images'
& $scp -i "$env:USERPROFILE\.ssh\id_ed25519_qalos" 'D:\qalos\.pi\out\cheetah\*.img' `
        'bramburn@192.168.0.46:/home/bramburn/qalos_images/'
```

### 6.1 PULL THE LOGS **BEFORE** TEARDOWN

**This is not optional. The logs exist only on the instance, and the
instance is the first thing you delete.** On 2026-09-28 the VM was torn
down with the build logs still on it and `b13.log` / `b14.log` were lost
with it. The build has to be repeated to regenerate them.

```powershell
New-Item -ItemType Directory -Force -Path 'D:\qalos\.pi\build-logs' | Out-Null
& $scp -i $key -r 'bramburn@34.105.204.203:/home/bramburn/*.log' 'D:\qalos\.pi\build-logs\'
& $scp -i $key 'bramburn@34.105.204.203:/home/bramburn/*.sh' 'D:\qalos\.pi\build-logs\'
```

Grab at minimum: every `bNN.log` (one per build attempt), the shared
`build.log` (`m` output tee'd by the build script), and the build driver
script itself. The `bNN.log` files are the **attempt record** — they are
the only evidence of *why* an attempt failed, and a failed attempt is
usually the one worth keeping.

**Checklist before `gcloud compute instances delete`:**

- [ ] images MD5-verified on every destination

- [ ] `*.log` and `*.sh` pulled off the instance

- [ ] GCS copy confirmed (`gcloud storage ls`)

If the instance is already gone, the logs are unrecoverable — the next
build regenerates them. Say so plainly rather than reconstructing from
memory.

**Byte-verify on every destination before teardown:**

```powershell
Get-ChildItem 'D:\qalos\.pi\out\cheetah\*.img' | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm MD5).Hash.ToLower(), $_.Name }
```

Compare against `md5sum *.img` on the VM and on macmini2024. All three
lists must be identical. Only then:

```powershell
gcloud compute instances delete qalos-gcp-20260928-160538 --zone=europe-west2-b --project=crypto-galaxy-846 --quiet
gcloud compute instances list --project=crypto-galaxy-846      # must show nothing
```

`autoDelete` on the boot disk removes the 500 GB with the instance —
confirm no `qalos*` disks remain.

---

## 7. What gets built (and what does not)

Flashable set produced by a successful cheetah build:

`boot.img`, `init_boot.img`, `dtbo.img`, `dtb.img`, `vendor_boot.img`,
`system.img`, `product.img`, `system_ext.img`, `system_dlkm.img`,
`vbmeta.img`, `vbmeta_system.img`, `vendor_kernel_boot.img`,
`ramdisk.img`, `vendor_ramdisk.img`, `vendor_kernel_ramdisk.img`,
`userdata.img`.

**Not produced: `vendor.img` and `super.img`.** See
[`LESSONS.md`](LESSONS.md) §4 — this is the open blocker for flashing
to real hardware and is the single most important thing to read before
attempting a flash.

---

## 8. Monitoring

Root `AGENTS.md` §2.8: the **LLM** owns the build's lifetime, not the
script. After the unit is running, set up a `mavis cron` that ticks
every 12 minutes and owns monitoring, delivery, and teardown. A build
failure is a diagnose-and-relaunch event, **not** a teardown trigger.

Judge progress by percentage and by `pgrep -c ninja`. `m` percentages sit
flat for minutes at a time; that is normal. Ninja's *total* edge count
drops as it runs (7,030 -> 6,618) because it re-plans; that is also
normal, not a stall.

Track cost per tick in a ledger (the 2026-09-28 run kept one at
`.pi/COST-TALLY.md`). Derive it from SKU rate x measured runtime and
label it an estimate — there is no BigQuery billing export on this
project, so no figure here is an invoiced amount.

---

## 9. Recovery when Spot reclaims the instance

SSH refuses, and the instance is gone from `gcloud compute instances list`.
Say so plainly. The 179 GB sync is lost; **every qalos fix is pushed** to
`feat/qa-lab-os-v1`, so recovery is: relaunch, `repo sync` (~32 min),
re-apply, rebuild. Do not attempt to reconstruct fixes from memory.
