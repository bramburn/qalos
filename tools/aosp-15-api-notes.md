# AOSP 15.0.0_r1 — API and build facts

> Verified facts about the AOSP tag qalos is pinned to
> (`android-15.0.0_r1`). Every entry was established by **reading the
> synced tree**, not from recall — five fixes on this project were
> guessed from memory and all five had to be walked back.
>
> If an entry here disagrees with what you read in the tree, **the tree
> wins** and this file is wrong; fix this file in the same commit.
>
> Related: [`aosp-15-fixes.md`](aosp-15-fixes.md) (upstream metalava
> issues), [`gcp/LESSONS.md`](gcp/LESSONS.md) (what went wrong in
> practice).

---

## Build environment

### `lunch` takes exactly ONE argument in AOSP 15

```bash
lunch qalos_cheetah-trunk_staging-userdebug     # correct
lunch qalos cheetah trunk_staging userdebug     # AOSP 16 form — wrong here
```

`build/envsetup.sh:442` splits a single argument on `-`. The
multi-argument form was introduced in AOSP 16.

### `TARGET_RELEASE` and all `RELEASE_*` flags are read-only

`build/make/core/product_config.mk:234` marks them read-only in product
config. A product makefile that assigns `TARGET_RELEASE := trunk_staging`
fails the build. Do not try to redirect a release flag.

### The release flag that breaks a blob-less device tree

`build/release/flag_values/trunk_staging/` defines
`RELEASE_KERNEL_CHEETAH_DIR` → `6.1/trunk-11970169`, but `repo sync` only
brings down `5.10/24Q3-12115410`. Since the flag is read-only, the
workaround is an **absolute symlink** in the tree, not a variable
override. See [`gcp/AGENTS.md`](gcp/AGENTS.md) §3.2.

### Never `set -u` around AOSP commands

`build/envsetup.sh:21` reads `$TOP` before assigning it. Under
nounset the shell dies with `line 21: TOP: unbound variable` and
`lunch` is never defined — which looks like a broken envsetup, not a
shell flag. Use `set -o pipefail` only.

### Passing the target to `m` outside `lunch`

`lunch` exports the target into its own sub-make only. For a
third-party product in a fresh `envsetup` pass, export explicitly:

```bash
export TARGET_PRODUCT=qalos_cheetah
export TARGET_RELEASE=trunk_staging
export TARGET_BUILD_VARIANT=userdebug
```

### `product_specific: true` is required for a product-local app

Our modules shipped in the product config need it, otherwise they are
not installed for a `userdebug` build of that product:

- `QaLab` (`android_app`)
- `aqa_server` (`cc_binary`)

### Machine type names

`c3-highmem-32` **does not exist.** The C3 family sizes are
`-4 / -8 / -22 / -44 / -88`. Check with
`gcloud compute machine-types list` before writing one into a script.

---

## The metalava API gate

A new `<permission>` in `frameworks/base/core/res/AndroidManifest.xml`
is new public API surface and fails
`api-stubs-docs-non-updatable` unless it is in `core/api/current.txt` or
marked `@hide`.

**Use the `@hide` comment convention AOSP itself uses:**

```xml
<!-- @SystemApi @hide
     qalos: signature permission that gates RemoteControlService. -->
<permission android:name="android.permission.REMOTE_CONTROL" ... />
```

`frameworks/base/core/res/AndroidManifest.xml` has 243 `@hide -->`
blocks; permissions carrying one are absent from `core/api/current.txt`,
permissions without one are present. Full write-up and the
`@FlaggedApi` dead end: [`gcp/LESSONS.md`](gcp/LESSONS.md) §4.

**Path notes that cost time:** the API text files are
`frameworks/base/core/api/`, not `frameworks/base/api/`. Entries look
like `Manifest.permission.ACCESS_NETWORK_STATE`.

---

## `frameworks/base` service API changes (AOSP 14 -> 15)

Ported in commits `53e7317` and `71604f6` on
`feat/qa-lab-os-v1`.

### `LocalServices` accessor

```java
LocalServices.getService(Class)      // AOSP 15
LocalServices.get(...)               // pre-15 — does not exist
```

### Screenshots: `ScreenCapture.ScreenshotHardwareBuffer`

- The class is **nested inside `ScreenCapture`**
  (`ScreenCapture.ScreenshotHardwareBuffer`, around line 186), not
  top-level.
- It has **no `close()`** method. The `hwBuf.close()` call that worked
  pre-15 is a compile error here.
- `DisplayManagerInternal.captureDisplay(int)` was **removed**. The
  replacement is `DisplayManagerInternal.userScreenshot(int)`
  (around line 131).
- `import android.window.ScreenshotHardwareBuffer` does not resolve —
  it is not in that package. The bogus import was removed in `f377443`.

### `HttpApiServer` internals

- `ROUTES` changed from a `static` field to an **instance** field.
- The route table calls `userScreenshot` (see above).
- Screenshot bytes are encoded with `Base64` and written via
  `java.io.FileOutputStream` — the pre-15 `hwBuf` path is gone.
- `RouteHandler` **throws `JSONException`**, and resolves services with
  `LocalServices.getService(...)`.

---

## Linux/SSH operator notes for this project

- **`pkill -f <pattern>` can kill the SSH session running it** (the
  pattern matches its own command line). Use `pkill -x`.
- Never pipe AOSP output through `Get-Content | Set-Content` on
  Windows — PS 5.1 re-encodes and can corrupt files. Use the file tools.
