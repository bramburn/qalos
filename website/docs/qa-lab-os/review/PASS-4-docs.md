# PASS 4 — docs review

**Scope:** Does the code match the docs? Are the API examples
executable? Does the build guide work on a clean checkout? Is the
agent dev guide complete? Is the decisions log consistent with the
code?

**Reviewer:** the same agent, documentation hat.

**Verdict:** **2 must-fix, 4 should-fix, 3 nit.** The docs are
mostly right; the issues are around placeholder patch numbers and
an outdated `architecture.md` claim.

## Findings

### F-4.1 — `architecture.md` says "translates HTTP requests into AIDL calls"

- **Status:** must-fix
- **File:** `website/docs/qa-lab-os/architecture.md:18`
- **Issue:** The phrase suggests the HTTP server makes Binder
  calls into the AIDL stub. In fact, the HTTP server holds a
  direct reference to the same `IRemoteControl.Stub` instance
  the service publishes — there is no Binder marshalling because
  both are in the same process.
- **Suggestion:** Replace with "translates HTTP requests into
  in-process calls on the IRemoteControl stub (no Binder
  marshalling because both halves run in system_server)."
- **Applied:** FIXED in `fix-ups`.

### F-4.2 — `build-guide.md` step 8 says `/screenshot?width=480&height=800&quality=85` but the on-device service does not actually down-scale

- **Status:** must-fix
- **File:** `website/docs/qa-lab-os/api.md:55-67`
- **Issue:** The docs say "downscale width" and "downscale height"
  but the on-device service passes the dimensions to
  `SurfaceControl.screenshot(width, height, displayId)`, which
  captures at the given resolution, not down-scales. There is no
  "scale to native" path.
- **Suggestion:** Reword the parameter docs to "capture width /
  capture height" (0 = native display size). Note that this
  changes the screenshot resolution, not the display resolution.
- **Applied:** FIXED in `fix-ups`.

### F-4.3 — The four `patches/*.patch` files are not real patches

- **Status:** must-fix
- **File:** `packages/apps/RemoteControlService/patches/*.patch`
- **Issue:** The hunks use `-X,Y` as a placeholder. A user who
  follows `build-guide.md` step 3 will run `apply-qalos.sh`, see
  the warnings, and have no way to know what to do.
- **Suggestion:** This is the same as F-1.2. Replace the four
  patches with `sed` scripts. The build guide will be updated
  accordingly.
- **Applied:** FIXED in `fix-ups` (folded into the F-1.2 fix).

### F-4.4 — `architecture.md` says the service is registered "after InputManagerService and ActivityManagerService have started"

- **Status:** should-fix
- **File:** `website/docs/qa-lab-os/architecture.md:44-48`
- **Issue:** The patch anchors on InputManagerService, but the
  service also depends on ActivityManagerService. The current
  patch order has the registration after InputManagerService,
  which is correct, but the docs do not explain WHY this order
  matters. A future maintainer might move it.
- **Suggestion:** Add a sentence: "The order matters because
  RemoteControlService uses LocalServices.getService() to look up
  InputManagerService and IActivityManager in onBootPhase, and
  both must have been published first."
- **Applied:** FIXED in `fix-ups`.

### F-4.5 — `api.md` documents the `down` field for `/key` as `bool` but the AIDL says `boolean`

- **Status:** should-fix
- **File:** `website/docs/qa-lab-os/api.md:130`
- **Issue:** AIDL's `boolean` is the Java type, not the JSON
  type. The JSON wire format is `true` / `false`. The docs say
  `bool`, which is correct for JSON but ambiguous.
- **Suggestion:** Add a one-line note: "the JSON wire format is
  lowercase `true` / `false`; the AIDL signature uses Java
  `boolean`."
- **Applied:** FIXED in `fix-ups`.

### F-4.6 — `build-guide.md` step 4 is the patch verify, but it is not in the right position

- **Status:** should-fix
- **File:** `website/docs/qa-lab-os/build-guide.md:74-82`
- **Issue:** The build guide currently puts the patch verify
  AFTER `apply-qalos.sh`. The verify should be BEFORE apply so
  the user knows in advance whether they are about to get a
  partial apply.
- **Suggestion:** Move step 4 (verify) before step 3 (apply).
  Update numbering.
- **Applied:** FIXED in `fix-ups`.

### F-4.7 — `agent-developer-guide.md` says "500 ms" is the settle time but does not explain how to tune it

- **Status:** should-fix
- **File:** `website/docs/qa-lab-os/agent-developer-guide.md:97`
- **Issue:** The 500 ms default is a rule of thumb. For snappy
  UIs (a list scroll) 200 ms is enough; for animations (screen
  transition) 800 ms is safer.
- **Suggestion:** Add a sentence: "Lower for snappy UIs, higher
  for animated transitions. The cost of a too-low value is a
  blurry screenshot that confuses the LLM."
- **Applied:** FIXED in `fix-ups`.

### F-4.8 — `decisions.md` is missing the LICENSE SPDX note from D-005b

- **Status:** nit
- **File:** `website/docs/qa-lab-os/decisions.md:D-005b`
- **Issue:** The decision entry says "Java and AIDL source files
  carry an SPDX Apache-2.0 license header" but the Python files
  we just wrote carry an SPDX MIT header. The decision is
  recorded but the convention is not — should add a sentence
  about the per-file SPDX line.
- **Applied:** FIXED in `fix-ups`.

### F-4.9 — `api.md` "Curl cookbook" example uses `jq` but does not mention Windows users

- **Status:** nit
- **File:** `website/docs/qa-lab-os/api.md:189-217`
- **Issue:** The examples use `jq` and `base64 -d`. On Windows
  PowerShell, the equivalents are `jq` (if installed) and
  `certutil -decode` or `[Convert]::FromBase64String`.
- **Applied:** DEFERRED. v0 docs target the Linux box. A
  Windows user would run the commands on the host's WSL or
  Linux VM. A note in the build guide covers this.

### F-4.10 — `README.md` of `packages/apps/RemoteControlService` references the docs by relative path

- **Status:** nit
- **File:** `packages/apps/RemoteControlService/README.md:38-40, 48-50`
- **Issue:** The relative paths use `../../../website/docs/...`
  which works in a GitHub view but not when the README is
  rendered locally. GitHub's blob-renderer resolves them.
- **Applied:** WONTFIX. GitHub-flavored Markdown is the
  primary target. The Docusaurus site has the canonical URLs.

## Summary

| Severity | Count | Fixed | Deferred/WONTFIX |
| --- | --- | --- | --- |
| must-fix | 2 | 2 | 0 |
| should-fix | 4 | 4 | 0 |
| nit | 3 | 1 | 2 |
| **Total** | **9** | **7** | **2** |

## Re-run

Re-run after the `fix-ups` commit. All must-fix items are FIXED.
The deferred items are documented in
[`review-log`](../review-log).

PASS 4 — **CLEAN**.
