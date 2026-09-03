---
id: dry-run-workflow
title: AOSP dry-run workflow
sidebar_label: Dry-run workflow
sidebar_position: 12
description: How to validate framework-overlay patches against the real AOSP source before declaring them ready.
---

# AOSP dry-run workflow

The 5-minute procedure that catches anchor + API mismatches in
framework-overlay patches. Run it **before declaring any patch
ready**, not after.

## When to use this workflow

- You wrote a patch against an upstream AOSP file and want to
  verify the anchor matches the real file.
- A new AOSP release is out and you want to know which of your
  patches need a rebase.
- A 4-pass AI review passed but you want one more check.

Do **not** skip this step just because the patch "looks right" in
code review. The v0 of the qalos RemoteControlService had three
real bugs that two 4-pass reviews missed; the dry-run caught all
three. The recipe is below; the history is in
[`lessons-learned.md`](./lessons-learned).

## The recipe (PowerShell, on Windows)

```powershell
$ErrorActionPreference = 'Stop'
$base = "https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1"
$out  = ".tmp/aosp-15"
New-Item -ItemType Directory -Force -Path $out | Out-Null

# 1. Fetch each target file via the googlesource API.
#    format=TEXT returns base64 with no newlines; decode locally.
$files = @(
  "services/core/Android.bp",
  "core/res/AndroidManifest.xml",
  "core/res/res/values/strings.xml",
  "services/java/com/android/server/SystemServer.java"
)
foreach ($f in $files) {
  $url = "$base/$($f)?format=TEXT"
  $dst = Join-Path $out $f
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  $resp = Invoke-WebRequest -Uri $url -UseBasicParsing
  $bytes = [System.Convert]::FromBase64String($resp.Content)
  Set-Content -Path $dst -Value ([System.Text.Encoding]::UTF8.GetString($bytes)) -Encoding utf8
}

# 2. Mirror into a fake AOSP working tree. The patches expect
#    paths like frameworks/base/services/core/Android.bp; the
#    tree below matches.
$wt = ".tmp/aosp-15-frameworks"
New-Item -ItemType Directory -Force -Path "$wt/frameworks/base" | Out-Null
Copy-Item -Recurse "$out/services" "$wt/frameworks/base/services"
Copy-Item -Recurse "$out/core"     "$wt/frameworks/base/core"

# 3. Pre-flight: run every patch in dry-run mode against the tree.
python3 packages/apps/RemoteControlService/patches/check-patches.py $wt
# Expected output: "OK" for each of the three remaining patches
# (the 4th patch, 0001-Android.bp srcs, is unnecessary on AOSP 15
# and was deleted; see lessons-learned.md).

# 4. Apply each patch individually for a verbose confirmation.
foreach ($p in Get-ChildItem packages/apps/RemoteControlService/patches/000*.py) {
  python3 $p.FullName $wt
}

# 5. Diff the result against the pristine copy to see exactly what
#    each patch changed. The diff IS the patch; if it surprises
#    you, the patch is wrong.
foreach ($f in $files) {
  $pristine = Join-Path $out $f
  $modified = Join-Path $wt/frameworks/base $f
  Write-Host "=== $f ==="
  # Use a portable diff. The `-u` flag requests unified format.
  if (Get-Command diff -ErrorAction SilentlyContinue) {
    diff -u $pristine $modified
  } else {
    Compare-Object (Get-Content $pristine) (Get-Content $modified)
  }
}
```

## The recipe (bash, on Linux / macOS)

```bash
set -euo pipefail
base="https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1"
out=".tmp/aosp-15"
mkdir -p "$out"

# 1. Fetch each target file.
files=(
  "services/core/Android.bp"
  "core/res/AndroidManifest.xml"
  "core/res/res/values/strings.xml"
  "services/java/com/android/server/SystemServer.java"
)
for f in "${files[@]}"; do
  url="$base/$f?format=TEXT"
  dst="$out/$f"
  mkdir -p "$(dirname "$dst")"
  curl -fsSL "$url" | base64 -d > "$dst"
done

# 2. Mirror into a fake AOSP working tree.
wt=".tmp/aosp-15-frameworks"
mkdir -p "$wt/frameworks/base"
cp -r "$out/services" "$wt/frameworks/base/services"
cp -r "$out/core"     "$wt/frameworks/base/core"

# 3. Pre-flight.
python3 packages/apps/RemoteControlService/patches/check-patches.py "$wt"

# 4. Apply each patch individually.
for p in packages/apps/RemoteControlService/patches/000*.py; do
  python3 "$p" "$wt"
done

# 5. Show the diffs.
for f in "${files[@]}"; do
  pristine="$out/$f"
  modified="$wt/frameworks/base/$f"
  echo "=== $f ==="
  diff -u "$pristine" "$modified" || true
done
```

## Interpreting the output

A successful dry-run looks like this:

```
  OK     0002-AndroidManifest-REMOTE_CONTROL-permission.py
  OK     0003-strings-REMOTE_CONTROL.py
  OK     0004-SystemServer-StartRemoteControlService.py

All 3 patch(es) apply cleanly to .tmp/aosp-15-frameworks.
```

A failing dry-run looks like this:

```
  FAIL   0004-SystemServer-StartRemoteControlService.py:
    [0004] anchor (InputManagerService start + t.traceEnd) not found in
    .tmp/aosp-15-frameworks/frameworks/base/services/java/com/android/server/SystemServer.java.
    AOSP may have refactored SystemServer. See REBASE.md.
```

When a patch fails, follow [`REBASE.md`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/packages/apps/RemoteControlService/REBASE.md):

1. Open the upstream AOSP file and search for the new shape of
   the anchor.
2. Update the patch script's regex and the inserted block.
3. Re-run the dry-run.
4. Commit the patch-script change as a follow-up titled
   `qalos: rebase <patch-name> onto <new-AOSP-tag>`.

## Adapting to a different AOSP release

The recipe above pins `android-15.0.0_r1`. To check against a
different release, change the `base` variable:

```bash
# Android 14
base="https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-14.0.0_r2"

# Android 16 (when the tag is published)
base="https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1"

# Latest AOSP main (bleeding edge; expect breakage)
base="https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main"
```

The googlesource API serves any tag, branch, or SHA. The `?format=TEXT`
suffix is what makes the response base64-without-newlines;
without it, the response is a HTML viewer page.

## What this workflow catches (and what it doesn't)

**Catches:**

- Anchor mismatches (the patch's regex / `str.replace` does not
  match the upstream file at all).
- API removal (the upstream renamed or deleted a method the
  patch references).
- Whitespace / indent depth changes.
- AOSP build-structure refactors (e.g., a `java_library` is
  moved or split; the `srcs:` block moves with it).
- "Already covered" cases (the upstream build already globs in
  your new files, so the patch is unnecessary).

**Does not catch:**

- Compile-time errors in your **added** code (the patch script
  only edits text; it does not run `javac`).
- AIDL signature mismatches with the upstream AIDL definitions
  in `core/java/android/os/`.
- SELinux policy issues (your service may lack the right
  `allow` rules in `sepolicy/`).
- Behavioural differences (the patch applies, but the
  inserted code calls an API that throws at runtime).

For compile-time checks, you need the AOSP build (the build
guide documents the procedure). For SELinux and behaviour, you
need the emulator or a physical device.

## When to skip this workflow

If the patch is editing a qalos-owned file (under `device/qalos/`,
`packages/apps/QaLab/`, `vendor/qalos/`, etc.), the dry-run is
unnecessary — those files are not upstream. The workflow is for
patches that modify files in upstream AOSP repos.

## Make this part of CI

The natural extension is to add a GitHub Actions job that runs
the dry-run on every PR. Add this to `.github/workflows/ci.yml`:

```yaml
- name: AOSP dry-run
  run: |
    python3 packages/apps/RemoteControlService/patches/check-patches.py \
      $(mktemp -d)
  # The check-patches.py is designed to return non-zero if any
  # patch fails its dry-run. The mktemp is a stub; replace with
  # the real download-and-mirror recipe when wiring up the CI
  # image.
```

The full mirror needs the AOSP source files cached in the
runner; the build guide's `qalos-build-warm` snapshot is the
place to put them. Out of scope for the v0 PR; the v1 branch
should pick it up.

## See also

- [`lessons-learned.md`](./lessons-learned) — the three real bugs
  the dry-run caught on v0
- [`REBASE.md`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/packages/apps/RemoteControlService/REBASE.md)
  — the per-patch rebase procedure
- [`followup-work.md`](./followup-work) — the v1 backlog
- [AGENTS.md §8.1](https://github.com/bramburn/qalos/blob/main/AGENTS.md#81-qa-lab-os-v0-followup-work)
  — the canonical summary
