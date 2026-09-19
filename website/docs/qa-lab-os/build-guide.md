---
id: build-guide
title: Build guide
sidebar_label: Build guide
sidebar_position: 6
description: Step-by-step instructions to build, flash, and verify QA Lab OS v0.
---

# Build guide

This guide walks through building QA Lab OS v0 on a Linux box,
flashing it to an emulator, and verifying the on-device service
responds. The AOSP build does **not** run on this Windows host; the
Linux box is mandatory.

## Prerequisites

- **OS:** Ubuntu 22.04 LTS (or 24.04 LTS). Bare metal or a VM with
  nested virtualisation enabled.
- **RAM:** 32 GB minimum. 64 GB recommended for the first build.
- **Disk:** 300 GB free. The `repo sync` working tree is ~200 GB
  before any build output; an emulator build adds another ~20 GB.
- **CPU:** 8+ cores. The first build is roughly linear in core
  count; expect 2-6 hours.
- **Network:** unmetered access to `https://android.googlesource.com`
  and `https://github.com`.

## Step 1 — install AOSP build dependencies

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    git gnupg flex bison gperf build-essential zip curl zlib1g-dev \
    gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev \
    x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev \
    libxml2-utils xsltproc unzip m4 bc openjdk-17-jdk-headless \
    python3 python3-pip rsync ccache jq
```

```bash
mkdir -p ~/bin
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    -o ~/bin/repo
chmod a+x ~/bin/repo
echo 'export PATH=~/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

Verify:

```bash
repo --version
```

## Step 2 — clone the qalos manifest

```bash
mkdir -p ~/aosp && cd ~/aosp
repo init -u https://github.com/bramburn/qalos -b feat/qa-lab-os-v0
repo sync -c -j$(nproc) --no-tags --no-clone-bundle
```

The first `repo sync` downloads ~200 GB and takes 1-2 hours on a
warm connection. Subsequent syncs are incremental.

## Step 3 — verify the patches

Before applying anything, run the patch verifier to confirm none of
the nine patches are silently broken by a future AOSP revision:

```bash
python3 ../qalos/packages/apps/RemoteControlService/patches/check-patches.py
```

Exit code 0 means all nine would apply cleanly. A non-zero exit
means one or more need a manual rebase (see step 5).

## Step 4 — apply the qalos overlay

```bash
../qalos/tools/apply-qalos.sh
```

This copies the qalos-specific files into the AOSP working tree and
applies the nine Python-based "patches" that gate the
RemoteControlService:

1. `0002-AndroidManifest-REMOTE_CONTROL-permission.py` — declares
   the `REMOTE_CONTROL` signature permission.
2. `0003-strings-REMOTE_CONTROL.py` — provides the permission
   labels.
3. `0004-SystemServer-StartRemoteControlService.py` — registers
   the service in `SystemServer`.
4. `0005-AndroidManifest-REMOTE_CONTROL-FlaggedApi.py` — annotates
   the permission with `@SystemApi @hide`.
5. `0006-services-core-aconfig-qalos.py` — appends the
   `aconfig_declarations` block to `services/core/Android.bp`
   (orphaned since `9d98413`; kept for potential future aconfig
   consumers).
6. `0007-core-api-current-txt-REMOTE_CONTROL.py` — removes
   REMOTE_CONTROL from `current.txt` (the `@hide` permission
   doesn't belong in the public stub).
7. `0008-system-lint-baseline-UnflaggedApi-REMOTE_CONTROL.py` —
   adds an UnflaggedApi baseline entry for REMOTE_CONTROL.
8. `0009-frozen-matrix-IAllocator-optional.py` — marks
   `IAllocator/ashmem` as `<optional>` in
   `system/libhidl/vintfdata/frozen/{5,6,7,8}.xml`.
9. `0010-system-current-txt-REMOTE_CONTROL.py` — adds
   REMOTE_CONTROL to `system-current.txt` at its alphabetical
   position.

> **Note:** the original v0 had a fourth patch
> (`0001-services-core-Android-bp-srcs.py`) that explicitly added
> the qalos Java sources to the `services.core` `srcs:` list. It
> was deleted in the `fix-ups-2` commit because AOSP-15's
> `services.core-sources` filegroup already globs
> `srcs: ["java/**/*.java"]`, which picks up the copied
> `com/qalos/remotectl/*.java` without an explicit entry. See
> [`lessons-learned.md`](./lessons-learned.md) for the full history.

`apply-qalos.sh` runs the patch checker first and refuses to
continue if any patch would not apply. Pass `--force` to override
(the failing patch will be skipped, the others will be applied).

If a patch fails, follow
[`REBASE.md`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/packages/apps/RemoteControlService/REBASE.md)
to resolve the conflict. The build is not blocked — manual edits
are fine — but the patch script should be updated so the next
rebase is mechanical.

Verify the changes are in place:

Verify the changes are in place:

```bash
ls frameworks/base/services/core/java/com/qalos/remotectl/
# expected: HttpApiServer.java  IRemoteControl.java  RemoteControlService.java

grep -n "REMOTE_CONTROL" frameworks/base/core/res/AndroidManifest.xml
# expected: a <permission ... /> entry for REMOTE_CONTROL

grep -n "StartRemoteControlService" frameworks/base/services/java/com/android/server/SystemServer.java
# expected: a t.traceBegin("StartRemoteControlService") line
```

The SELinux policy overlay is wired at
`vendor/qalos/qalos_emulator/sepolicy/` via
`BOARD_VENDOR_SEPOLICY_DIRS` in `device/qalos/qalos_emulator/BoardConfig.mk`
(line 44). AOSP 15 enforces Treble: vendor policy (loaded from
`BOARD_VENDOR_SEPOLICY_DIRS`) cannot add allow rules to coredomain
types like `system_server` directly, so the overlay is compiled
into the vendor image and `apply-qalos.sh` copies it into place.

> **Note:** the `sepolicy/` directory under
> `device/qalos/qalos_emulator/` is kept on disk for historical
> reference; the active overlay lives at
> `vendor/qalos/qalos_emulator/sepolicy/`.

## Step 5 — build

```bash
source build/envsetup.sh
lunch qalos_emulator-trunk_staging-userdebug
m -j$(nproc)
```

> **AOSP-15 lunch format:** the third segment is the "release label",
> required since AOSP-15. For qalos it is fixed to `trunk_staging`.
> The 2-part form (`lunch qalos_emulator-userdebug`) is rejected with:
>
> ```text
> Invalid lunch combo: qalos_emulator-userdebug
> Valid combos must be of the form <product>-<release>-<variant>
> ```

First build: 2-6 hours. The output is at
`out/target/product/qalos_emulator/qalos_emulator-img-eng.*.zip` (or
similar; the exact name depends on the build id).

## Step 6 — launch the emulator

```bash
emulator -no-snapshot -writable-system
```

The first launch takes a few minutes as the userdata image is
created.

## Step 7 — tunnel the API port

```bash
adb forward tcp:9000 tcp:9000
```

`adb forward` is the auth boundary for v0. Without it, the service
is not reachable from the host.

## Step 8 — verify

```bash
curl http://localhost:9000/health
# expected: {"status":"ok","device":"...","android":"15"}

curl http://localhost:9000/display
# expected: {"width":1080,"height":2400}

curl http://localhost:9000/foreground
# expected: {"package":"com.android.launcher"}

curl -X POST http://localhost:9000/tap \
    -H 'Content-Type: application/json' \
    -d '{"x": 540, "y": 1200}'
# expected: {"status":"ok"}
```

If `curl` returns a connection refused, check that the emulator is
running and that the port forward is active:

```bash
adb devices                       # emulator-5554 should be listed
adb forward --list                # tcp:9000 tcp:9000 should be listed
```

## Step 9 — try the Python client

In a separate terminal:

```bash
cd ../qalos/tools/qa-lab-os
pip install -e ".[test]"
```

```python
from qa_lab_os import QaLabDevice

with QaLabDevice("localhost", 9000) as device:
    print(device.health())
    print(device.display_size)
    device.tap(540, 1200)
    device.screenshot().save("screen.png")
```

## Rebase runbook

When a new AOSP release shifts the file layout of the nine patched
files, follow the procedure in
[`packages/apps/RemoteControlService/REBASE.md`](https://github.com/bramburn/qalos/blob/main/packages/apps/RemoteControlService/REBASE.md).
The short version:

1. Run `check-patches.py` after every `repo sync` that bumps the
   AOSP pin.
2. For each failing patch, open the upstream AOSP file the patch
   anchors on (the patch's source comment names the file) and
   update the patch script in `patches/` so its anchor matches the
   new file content. Patches are Python source-of-truth — the diff
   between the script and the upstream file is the change being
   applied. Do NOT use `git apply`; the patches do not produce diff
   files.
3. Re-run `check-patches.py` until all nine report OK.
4. Commit the script change with a `qalos: rebase <patch-name> ...`
   message and open a PR against `main`.

## Cost and time budget

| Step | Time (first run) | Time (subsequent) |
| --- | --- | --- |
| apt install | 5 min | n/a |
| `repo init` + `repo sync` | 1-2 hours | 5-10 min |
| `apply-qalos.sh` | < 1 min | < 1 min |
| First `m` | 2-6 hours | n/a |
| Incremental `m` (after a Java edit) | n/a | 2-5 min |
| First `emulator` boot | 2-3 min | 30 s |

## Step 10 — re-run the on-host tests

This step is optional but recommended. The Python client and mock
server have a 51-test pytest suite that runs entirely on the
host:

```bash
cd ../qalos/tools/qa-lab-os
pip install -e ".[test]"
pytest
```

The suite verifies every endpoint against the mock server and
exercises the error paths. It does not require an AOSP build.

## Step 11 — package the build for the lab

If you want to share the v0 build across multiple physical devices,
package the userdata + system images and follow the existing qalos
cloud-fallback flow ([`getting-started/do-build`](../getting-started/do-build.md) or
[`getting-started/aliyun-build`](../getting-started/aliyun-build.md)). The
RemoteControlService is part of `system.img` and is included in the
golden image automatically.

The total one-time cost of standing up a v0 build environment is
~half a working day. After that, the incremental loop is minutes.

## Troubleshooting

- **`pm list permissions` shows REMOTE_CONTROL with an empty
  label** — the `0003-strings-REMOTE_CONTROL.py` did not apply.
- **`SystemServer` crashes on boot** — the
  `0004-SystemServer-StartRemoteControlService.py` did not apply
  or the inserted trace block is in the wrong place. Check
  `adb logcat | grep RemoteControlService` for the stack trace.
- **HTTP server does not respond** — verify the service is
  registered: `adb shell dumpsys activity services | grep
  qalos_remote_control`.

For anything else, file an issue with the output of
`adb logcat -d | grep -iE "RemoteControl|QaRemoteCtl"`.
