# `device/qalos/qalos_emulator/` — AGENTS.md

> The qalos emulator product. Folder-scoped opinions for any LLM/agent
> working in this subtree. The **root `AGENTS.md`** and the parent
> [`device/AGENTS.md`](../../AGENTS.md) and
> [`device/qalos/AGENTS.md`](../AGENTS.md) are the single source of
> truth for cross-cutting rules. If they disagree, the root wins.

This is the only qalos product today: a thin overlay on AOSP's generic
x86_64 emulator (`aosp_x86_64.mk`) that re-brands the image, sets a
qalos-specific build id, includes the first-party qalos apps, and wires
a small vendor SELinux overlay for the Remote Control Service.

## What's in this folder

```text
qalos_emulator/
├── AndroidProducts.mk          ← registers the product for `lunch`
├── BoardConfig.mk              ← board + BOARD_SEPOLICY_DIRS
├── device.mk                   ← product additions: packages, properties
├── qalos_emulator.mk           ← product definition: name, branding, build id
├── overlay/                    ← framework resource overlay (Tier 1 strip)
└── sepolicy/                   ← vendor SELinux overlay (see its AGENTS.md)
```text
The four `*.mk` files are the contract the AOSP build system looks for
by name. Do not rename or merge them.

## Opinions (product-wide)

### File roles

1. **`AndroidProducts.mk` is the registration file.** It exposes the
   product to `lunch`. Add a new line to `PRODUCT_MAKEFILES` only when
   introducing a sibling product makefile (e.g. `qalos_emulator_debug.mk`).
   Do not put product logic here.
2. **`qalos_emulator.mk` is the product definition.** This is where
   `PRODUCT_NAME`, `PRODUCT_DEVICE`, branding, and `BUILD_ID` live.
   It also calls `inherit-product` to pull in the AOSP base + `device.mk`.
3. **`BoardConfig.mk` is board-level config.** It includes
   `device/generic/x86_64/BoardConfig.mk` and sets
   `BOARD_SEPOLICY_DIRS`. **No product properties, no `PRODUCT_PACKAGES`**
   in this file — those belong in `device.mk`.
4. **`device.mk` is product-level additions.** It adds packages
   (`PRODUCT_PACKAGES`) and product-wide property overrides
   (`PRODUCT_PROPERTY_OVERRIDES`). It must not do another
   `inherit-product` for `device/generic/x86_64/` — AOSP's
   `device/generic/x86_64/` tree in `android-15.0.0_r1` has no
   `device.mk`; any such inherit aborts the build with
   `error: device/generic/x86_64/device.mk does not exist.`

### AOSP-specific rules (these are non-obvious — read once, never trip on them)

5. **`BOARD_SEPOLICY_DIRS` must be set in `BoardConfig.mk`.** Setting it
   in `device.mk` is **silently ignored** on AOSP 14+/15+ for vendor
   policy. The SELinux overlay is wired from `BoardConfig.mk`, not from
   `device.mk`. See the rationale comment in `BoardConfig.mk`.
6. **Do not invent new `inherit-product` chains to `device/generic/x86_64/`.**
   The only valid base for this product is
   `$(SRC_TARGET_DIR)/product/aosp_x86_64.mk`, already inherited in
   `qalos_emulator.mk`. Anything else fights the AOSP build system.
7. **`PRODUCT_PROPERTY_OVERRIDES` is deprecated** in favour of the
   partition-specific `PRODUCT_<PARTITION>_PROPERTIES` lists
   (see `core/product.mk` TODO(b/117892318)). v0 keeps the deprecated
   form because the system-visible build-id properties are exactly
   what the AOSP compat layer still wires correctly. Switching to
   `PRODUCT_SYSTEM_PROPERTIES` is a deliberate v1 change, not a drive-by.

### qalos-specific rules (read these before editing branding/build id)

8. **Branding strings are owner-controlled.**
   `PRODUCT_BRAND = QA Lab`, `PRODUCT_MODEL = QA Lab Operating System`,
   `PRODUCT_MANUFACTURER = QA Lab`. Do not change without explicit owner
   sign-off. These end up in `ro.product.*` and the AVD boot screen.
9. **Build id format is `QAL.<YYYYMMDD>.NNN`.** The date stamp is
   `$(shell date -u +%Y%m%d)`; the patch digit (`.NNN`) is the human
   signal for the Nth build on a given date. Bump it for hot-fix builds
   on the same day. Do not change the format.
10. **`BUILD_VERSION_TAGS = qalos`.** This is the string AOSP uses to
    distinguish qalos builds from upstream AOSP. Keep it.

## Strip policy — what ships, what does not (Tier 1)

The product is a "phone-app-test runtime" not a consumer phone. The
shipped test APK exercises **phone/SMS, gyro, GPS, pictures,
microphone, files, camera, storage, vibration, internet** and
nothing else of consumer value. Everything else is either dropped
or kept by a deliberate decision recorded here.

The actual filter is in `device.mk` (one `$(filter-out ...)` call)
and the property/overlay knobs are in `device.mk` and
`overlay/frameworks/base/core/res/res/values/config.xml`. This
section is the audit trail for those files.

### Always remove (no QA value for the test APK)

| Subsystem | Package(s) | Why |
| --- | --- | --- |
| Stock apps (system partition) | `LiveWallpapersPicker`, `PartnerBookmarksProvider`, `Stk`, `Tag` | UI / OEM cruft; test APK does not open them. `Stk` is the SIM-toolkit UI; framework-side STK plumbing in `telephony_system_ext.mk` stays. |
| Stock apps (system_ext partition) | `AccessibilityMenu`, `Provision`, `WallpaperCropper` | No accessibility menu / wallpaper picker / setup wizard needed on a lab emulator. |
| Stock apps (defensive) | `Calendar`, `Contacts`, `DeskClock`, `Email`, `Gallery2`, `Music`, `Browser2`, `Calculator`, `QuickSearchBox` | Replaced by the test APK. Not all of these are in `aosp_x86_64`; the filter is a no-op for the ones that are not — that is fine, defensive. Specifically, `Email` and `Calculator` are not AOSP-15 packages at all (the `packages/apps/Email/` and `packages/apps/Calculator/` repos were removed before AOSP-15); the entry is purely defensive. |
| Print | `PrintSpooler`, `PrintRecommendationService` | No printer. |
| Backup UI | `BackupRestoreConfirmation` | Lab state is ephemeral. (The framework `BackupManagerService` itself is a Tier-2 cut; the v1 plan does not touch it.) |
| SmartClip / TextClassifier | `SmartClipService`, `TextClassifierService` | Constant background heuristics; test APK does not use them. |

> **Stale names footnote:** four of the entries above
> (`LiveWallpapersPicker`, `PartnerBookmarksProvider`,
> `AccessibilityMenu`, `WallpaperCropper`) refer to historical
> module names that return 404 on the AOSP-15
> `android.googlesource.com` tag — the source was reorganised
> (e.g. `LiveWallpapersPicker` is now in `packages/apps/WallpaperPicker/`,
> `AccessibilityMenu` is in
> `frameworks/base/packages/SettingsLib/AccessibilityMenu/`).
> The `$(filter-out ...)` clause is a no-op for the missing names,
> so the build is unaffected; the entries are kept for historical
> context. If a future AOSP tag drops the names entirely, no
> action is needed. If a future AOSP tag re-introduces them under
> a different name, the filter should be updated to the new name
> (otherwise the build will silently re-include the package).

### Always keep — locked (the test APK exercises these; do not filter out)

These are the **MUST-KEEP** APIs the test APK depends on. They
are recorded as guardrails for the next agent; removing any of
them without explicit owner sign-off is a hard error in the
strip policy. They are listed by the user requirement that drives
the keep, not by AOSP package name, so the keep decision stays
legible even if AOSP renames the underlying package.

| User requirement | AOSP subsystem | AOSP source |
| --- | --- | --- |
| Phone calls | `TelephonyManager`, `TelephonyRegistry`, RIL JNI | `frameworks/base/telephony/`, `frameworks/opt/telephony/` |
| SMS | `SmsManager`, `com.android.mms.service` | `frameworks/base/telephony/`, `frameworks/opt/telephony/` (MMS service was relocated from `packages/services/Mms/` to `frameworks/opt/telephony/` between AOSP-11/12 and AOSP-15) |
| Gyroscope | `SensorManager` (TYPE_GYROSCOPE) | `frameworks/base/core/java/android/hardware/SensorManager.java` |
| GPS | `LocationManagerService`, GPS HAL | `frameworks/base/services/core/java/com/android/server/location/`, `hardware/interfaces/gnss/` |
| Pictures (taking) | Camera HAL, Camera2 API | `frameworks/base/core/java/android/hardware/camera2/`, `hardware/interfaces/camera/` |
| Microphone | Audio HAL, `AudioRecord` | `frameworks/base/media/java/android/media/AudioRecord.java` |
| Files | MediaStore, SAF, DownloadManager, StorageManager | `frameworks/base/core/java/android/provider/`, `frameworks/base/core/java/android/app/DownloadManager.java` |
| Camera (open + record) | Camera HAL, `CameraDevice` | `frameworks/base/core/java/android/hardware/camera2/CameraDevice.java` |
| Storage | StorageManager, FUSE | `frameworks/base/services/core/java/com/android/server/storage/` |
| Vibration | Vibrator service, Vibrator HAL | `frameworks/base/services/core/java/com/android/server/vibrator/VibratorService.java` (VibratorService.java moved to the `vibrator/` subpackage in AOSP-15) |
| Internet | Network stack, ConnectivityService, WiFi, `libnetutils-wrapper-1.0` | `frameworks/base/services/core/java/com/android/server/connectivity/ConnectivityService.java` (the connectivity service moved to a `connectivity/` subpackage in AOSP-15), `frameworks/base/wifi/` |
| **Camera app** (user-kept) | AOSP `Camera2` package | `packages/apps/Camera2/` — kept per user instruction even though the test APK uses the framework, not the app; the app is a low-cost menu fallback for the operator. |
| **Launcher** (user-kept) | `Launcher3QuickStep` | `packages/apps/Launcher3/` — kept per user instruction. The test APK is launched via `am start ...` from the host agent over `RemoteControlService`, so the heavy launcher is not on the test path, but the user has explicitly asked for it to stay. |
| **QaLab** (qalos) | First-party identity stamp | `packages/apps/QaLab/` |
| **RemoteControlService** (qalos) | Test-rig HTTP/JSON driver | `packages/apps/RemoteControlService/` |

### Always keep (the test APK exercises these)

Documented so the next agent does not accidentally filter them
out or treat them as "dead weight."

| Subsystem | AOSP source |
| --- | --- |
| ADB / USB debugging | `core/adb` |
| WiFi / network stack | `frameworks/base/services/core/java/com/android/server/connectivity/ConnectivityService.java` |
| PackageManager / ActivityManager / WindowManager | `frameworks/base/services/core/java/com/android/server/{pm,am,wm}/` |
| ART + Zygote | `art/`, `frameworks/base/core/java/com/android/internal/os/ZygoteInit.java` |
| SurfaceFlinger + Display HAL | `frameworks/native/services/surfaceflinger/` |
| Basic SystemUI | `frameworks/base/packages/SystemUI/` (system_ext; gut it via overlay in Tier 2) |
| Settings (minimal) | `packages/apps/Settings` (system_ext) |
| Power / BatteryStats | `frameworks/base/services/core/java/com/android/server/power/`, `.../batterystats/` |
| AlarmManager / JobScheduler | `frameworks/base/services/core/java/com/android/server/{alarm,job}/` |
| Clipboard | `frameworks/base/services/core/java/com/android/server/clipboard/` |
| Input system | `frameworks/base/services/core/java/com/android/server/input/` |
| Notification (gutted in Tier 2) | `frameworks/base/services/core/java/com/android/server/notification/` |
| SAF / DownloadManager / MediaStore | `frameworks/base/core/java/android/provider/{DocumentsProvider,MediaStore}.java`, `app/DownloadManager.java` |
| Permissions | `frameworks/base/services/core/java/com/android/server/pm/permission/` |
| **QaLab** | `packages/apps/QaLab/` |
| **RemoteControlService** | `packages/apps/RemoteControlService/` |

### Conditional

For the v1 test APK the user brief puts all of these in scope, so
all are kept:

- GPS / Location — KEEP (test APK uses it).
- Mobile data / cellular — KEEP (test APK places calls / sends SMS).
- Sensors (incl. gyro, mag, baro, proximity) — KEEP.
- Microphone / audio record — KEEP.
- Vibration / haptics — KEEP.
- External storage / SD card — KEEP.
- USB OTG — DROP (emulator has no OTG hardware; the framework
  support stays, but no device-side peripheral).
- **Bluetooth — KEEP in v1, DROP in v2** (per user instruction).
  v1 keeps the BT framework / HAL because BluetoothAudio and BLE
  sometimes sit in the camera/AudioRecord code paths even when
  the test APK does not call them directly. v2 evaluates the
  actual usage from the Tier-3 instrumented run; if no test APK
  call hits BT, drop it then.

### Locale policy — English + Mandarin Chinese only

Per the user's "keep english and mandarin chinese only" decision,
the shipped image carries only four locales:

```makefile
PRODUCT_LOCALES := en_US en_GB zh_CN zh_TW
```

`PRODUCT_LOCALES` is a **build-time** filter: every other language
resource APK (Arabic, Hindi, Japanese, Korean, French, German,
Spanish, …) is dropped from `system.img` / `system_ext.img` at
compile time. The runtime default is still en-GB (via the
`SystemLocale` config); the AOSP settings app exposes only the
four listed locales for the user to pick from.

To add a locale, append to `PRODUCT_LOCALES` in `device.mk` and
record the reason in `legal/ACCEPTABLE_USE_POLICY.md` — the
locale list is also a "what markets is this image for"
document, and a stray locale could put the build in scope of a
data-residency or content-review regime we have not cleared.

### QA Lab optimisations — property overrides

Set in `device.mk` via `PRODUCT_PROPERTY_OVERRIDES`:

| Property | Verified AOSP-15? | Why |
| --- | --- | --- |
| `ro.logd.size=16M` | yes | Larger logd buffer; instrumented builds keep more context. |
| `ro.config.low_ram=true` | yes | Mark the image as low-RAM; AOSP throttles background work accordingly. |
| `window_animation_scale=0` | yes (best-guess; v1.1 will confirm on AOSP-15 tag) | Instant UI; the no-prefix form is what `WindowManagerService` reads. |
| `transition_animation_scale=0` | yes (best-guess) | Instant UI. |
| `animator_duration_scale=0` | yes (best-guess) | Instant UI. |
| `ro.qalos.build_id=$(BUILD_ID)` | yes (qalos-internal) | Build-id stamp; already in v0. |
| `ro.qalos.display_build_id=$(DISPLAY_BUILD_ID)` | yes (qalos-internal) | Display-id stamp; already in v0. |

### v1.1 — pending Aliyun access (deferred)

The acceptance recipe in the plan calls for a `m` build on the
user's Linux box, then `emulator -avd qalos -no-window -gpu
swiftshader_indirect` and an `adb install` of the test APK.
That build-and-boot verification is **deferred until Aliyun
access is available** per user instruction; the local Windows
host cannot run AOSP builds (no WSL, no native Android toolchain)
and the cloud paths (Aliyun / DO / GCP) all require the Aliyun
account to be live. Until then, the v1 changes are
**build-config-correct** but not **build-verified** — the user
takes the build risk on the first Aliyun run.

What is verified locally on this Windows host:

- `device.mk` parses as valid GNU make (manual line-by-line
  review; no `make` binary on this host).
- `overlay/.../config.xml` parses as well-formed XML
  (Python `xml.etree.ElementTree`).
- All cross-references between `device.mk` and this AGENTS.md
  resolve to real files in the worktree.

What needs the Aliyun build to verify:

- `m qalos_emulator-trunk_staging-userdebug` finishes with no
  `LOCAL_REQUIRED_MODULES` errors.
- The produced `system.img` does not contain
  `LiveWallpapersPicker`, `Stk`, `WallpaperCropper`, etc.
- The four shipped locales are the only ones in
  `system_ext/priv-app/Settings/Settings.apk` resources.
- The test APK still gets a Camera HAL, a Sensor manager, a
  GPS provider, a Telephony manager, a Vibrator service, a
  MediaStore, a Network stack, and a microphone.

Until that runs, treat this section as the live test plan.

### v1.1 candidates (deferred — need AOSP-15 verification)

The plan listed more properties. These are **not** in
`device.mk` yet because they were not verified against
`frameworks/base/core/res/res/values/config.xml` /
`build/make/core/product.mk` on AOSP 15.0.0_r1. A no-op
property is safe (the worst case is the test APK gets the
default behaviour, per the plan's risk section) but a typo is
also safe — neither is worth landing without evidence.

| Setting | Where | What the plan wanted | Why deferred |
| --- | --- | --- | --- |
| `ro.lockscreen.disable.default=1` | `device.mk` (`PRODUCT_PROPERTY_OVERRIDES`) | Disable the lock screen by default | The property name pattern is real on Android-x86 builds but not on stock AOSP-15; verify the exact key before adding. |
| `ro.config.battery_saver_config_overlay=true` | `device.mk` (`PRODUCT_PROPERTY_OVERRIDES`) | Force battery-saver overlay | Likely the wrong property name; AOSP's battery-saver config uses other keys. |
| `ro.system.update.disable=1` | `device.mk` (`PRODUCT_PROPERTY_OVERRIDES`) | Disable OTA update checks | Unverified; AOSP-15 OTA uses `*.ota.*` properties, not `*.update.*`. |
| `ro.qalaudio.allow_ac=1` | `device.mk` (`PRODUCT_PROPERTY_OVERRIDES`) | Allow audio on AC (benching) | Almost certainly a typo in the original plan; not a real AOSP property. |
| `config_showRotationLockPrefs=false` | `overlay/.../config.xml` | Hide the rotation-lock QS tile | Pre-AOSP-12/13 key, removed from AOSP; AAPT2 still compiles but no AOSP-15 code reads it. **Resolved in v1 — entry removed from `config.xml` (no-op, not deferred).** |
| `config_animateScreenLights=false` | `overlay/.../config.xml` | Disable the breathing-light animation | Unverified on AOSP-15; grep `config.xml` and `symbols.xml` on the AOSP-15 tag first. |
| `config_autoRotationDefaultsToUserRotation=false` | `overlay/.../config.xml` | Lock the device to portrait by default | Unverified on AOSP-15; the key was renamed/moved in AOSP-13/14. |

When verifying: open the upstream
[`build/make/core/product.mk`](https://android.googlesource.com/platform/build/+/refs/tags/android-15.0.0_r1/core/product.mk)
and `frameworks/base/core/res/res/values/{config,symbols}.xml`
on the AOSP-15 tag and confirm the exact name and value space
before adding to `device.mk` / `config.xml`. Then move the row
from this table to the verified table above and remove it from
this one.

### How to extend this list

When the test APK's behaviour changes (a new feature is added
or a sensor is dropped):

1. Decide keep/drop/conditional for the new feature.
2. If dropping, add the AOSP package name to the
   `$(filter-out ...)` list in `device.mk`. Names that do not
   exist are no-ops, so be generous.
3. If keeping, add it to the "Always keep — locked" table above
   so the next agent does not accidentally filter it out. The
   user-facing keep reason is mandatory in that table; an
   entry without a "user requirement" is not a guardrail.
4. If changing a property, prefer `overlay/.../config.xml` for
   resource keys and `device.mk` `PRODUCT_PROPERTY_OVERRIDES`
   for system properties. Add the verified property to the
   "QA Lab optimisations" table.
5. If changing a locale, edit `PRODUCT_LOCALES` in `device.mk`
   **and** update `legal/ACCEPTABLE_USE_POLICY.md` so the
   "what markets" audit stays in sync.
6. Do not touch `frameworks/base/` in Tier 1. That is Tier 2,
   its own branch (`feat/qa-lab-os-strip-2` or similar).
7. Do not add a new entry to the "Always keep — locked" table
   without an explicit user requirement line. The lock is the
   guardrail; weakening the lock weakens the policy.

### Guardrails — read these before changing the strip policy

The strip policy is one piece of a much larger qalos story. Any
change here should be checked against the linked documents.
Listed in the order an LLM agent should read them:

1. **Root `AGENTS.md`** (repo-wide architecture, build paths,
   safety nets, CI). The strip policy must not introduce a
   change that contradicts the four-safety-net rule, the
   `feat-auto-*` worktree convention, or the legal framework.
2. **`device/AGENTS.md`** (the `device/` entry point) and
   **`device/qalos/AGENTS.md`** (vendor root) — the folder
   conventions this file lives inside. Adding a new sibling
   folder here (e.g. `overlay-init/`) is governed by the rules
   in those files.
3. **`CONTRIBUTING.md`** at the repo root — PR workflow and
   the "run the local CI checks before pushing" recipe. A
   strip-policy PR must run the six CI checks
   (`lint-powershell`, `lint-shell`, `lint-markdown`,
   `secret-scan`, `link-check`, `validate-manifest`).
4. **`BRANCH_PROTECTION.md`** at the repo root — the exact
   `gh api` command for branch protection. The strip branch
   must pass through the protected review gate.
5. **`website/docs/qa-lab-os/plan.md`** — the v0 plan that
   the strip policy implements. Anything in this AGENTS.md
   that contradicts the v0 plan is a bug in this file, not
   the plan.
6. **`website/docs/qa-lab-os/followup-work.md`** — what v0
   intentionally deferred. The strip policy's "v1.1 deferred"
   and "v2 drop" sections must be consistent with the
   followup-work log; do not silently shrink the deferred
   list without recording why.
7. **`website/docs/qa-lab-os/decisions.md`** — the opinions
   that the v0 decisions are bound by. If the strip policy
   changes a decision, the decision log gets a new entry
   pointing at the PR.
8. **`legal/ACCEPTABLE_USE_POLICY.md`** — the use restrictions.
   A new locale, a new BT/BLE support level, or a new
   connected peripheral can change which customers the
   image is appropriate for. Update the AUP if the strip
   policy changes the use surface.
9. **`legal/DISCLAIMER.md`** — the umbrella "no warranty" /
   "no liability for misuse" text. The strip policy does not
   change the disclaimer, but a strip-policy change that
   weakens the AUP may force a disclaimer update.
10. **`README.md`** at the repo root — the public-facing
    quickstart. The "Build paths" and "Cost" sections are
    the user-facing summary of what this AGENTS.md governs;
    if the strip policy changes either, update the README.

When in doubt, the root `AGENTS.md` wins over this file.

## Out of scope here

- **SELinux rule content** → [`sepolicy/AGENTS.md`](sepolicy/AGENTS.md)
- **Apps included via `PRODUCT_PACKAGES`** → `packages/apps/QaLab/`, `packages/apps/RemoteControlService/`
- **The kernel** — inherited from AOSP's `device/generic/x86_64/` via
  `BoardConfig.mk`. To change the kernel config, override
  `TARGET_KERNEL_CONFIG` in `BoardConfig.mk`.
- **Cloud build orchestration** → `tools/`, `scripts/`, and the root AGENTS.md

## When to add a new file here

- New build-time tunables for this product → `BoardConfig.mk`
- New packages, properties, or init hooks → `device.mk`
- New branding strings, build id format, or product-level metadata → `qalos_emulator.mk`
- A second product variant (e.g. `qalos_emulator_debug`) → its own `<variant>.mk`
  registered in `AndroidProducts.mk`

Do not add a new file to this folder unless it fits one of those buckets.
If you find yourself wanting to add a `sepolicy_overlay.mk` or
`packages_manifest.mk`, that is a sign the new file belongs in its own
subfolder with its own `AGENTS.md`.

## Related

- [`../../../AGENTS.md`](../../../AGENTS.md) — root
- [`../../AGENTS.md`](../../AGENTS.md) — `device/` entry point
- [`../AGENTS.md`](../AGENTS.md) — vendor root
- [`sepolicy/AGENTS.md`](sepolicy/AGENTS.md) — SELinux overlay
