# qalos — AGENTS.md

> The canonical, machine-readable architecture doc for qalos. Any agent (or
> human) picking up this repo should read this first.
>
> **The human-facing mirror is at <https://bramburn.github.io/qalos/docs/architecture/overview>.**
> If the two ever disagree, this file wins. PRs that change architecture
> MUST update both.

---

## 0. Quick orientation

- **What this is:** an AOSP fork (`android-15.0.0_r1`) for QA Lab use. First target is the x86_64 emulator (`qalos_emulator-userdebug`).
- **Three build paths:** Local Linux box (primary), DigitalOcean droplet (fallback #1), Aliyun ECS (fallback #2).
- **Single source of truth for on-host build steps:** `tools/do-build.sh`. Both cloud orchestrators invoke it.
- **Repo:** <https://github.com/bramburn/qalos> · **Docs site:** <https://bramburn.github.io/qalos/> · **License:** MIT (qalos) + Apache 2.0 (AOSP)

## 1. Folder layout

```
qalos/
├── AGENTS.md                      ← you are here
├── README.md                      ← public-facing quickstart
├── CONTRIBUTING.md                ← PR workflow, code style, CI
├── CODE_OF_CONDUCT.md
├── BRANCH_PROTECTION.md            ← exact gh api command to apply branch protection
├── LICENSE                        ← MIT for qalos + Apache 2.0 attribution for AOSP
│
├── .github/                       ← GitHub-side config
│   ├── CODEOWNERS                 ← review-request routing
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── ISSUE_TEMPLATE/            ← bug_report.md, feature_request.md
│   └── workflows/
│       ├── build.yml              ← DO build on push/main + manual
│       ├── ci.yml                 ← NEW: static checks (no AOSP)
│       └── deploy-docs.yml        ← NEW: Docusaurus → GitHub Pages
│
├── default.xml                    ← the AOSP manifest; pins android-15.0.0_r1
├── upstream.xml                   ← verbatim copy of AOSP's default.xml
│
├── device/qalos/qalos_emulator/   ← qalos product makefile (branding, build id)
├── packages/apps/QaLab/           ← the only first-party qalos app
│
├── tools/                         ← WINDOWS ORCHESTRATORS (.ps1) + ON-HOST (.sh)
│   ├── apply-qalos.sh             ← on-host: copy qalos content into AOSP tree
│   ├── setup-droplet.sh           ← on-host: install AOSP build deps
│   ├── do-build.sh                ← on-host: the AOSP build (single source of truth)
│   ├── doctl-*.ps1                ← DO path (Windows)
│   └── aliyun-*.ps1               ← Aliyun path (Windows)
│
├── scripts/                       ← macOS / LINUX ORCHESTRATORS (.sh)
│   ├── aliyun-install.sh
│   ├── aliyun-smoke-test.sh
│   ├── aliyun-setup-base.sh
│   ├── aliyun-build.sh
│   └── lib/
│       ├── aliyun-common.sh       ← aliyon(), get_state(), save_state(), smallest_in_stock_instance_type()
│       └── log.sh                 ← log_info/warn/error/fatal with color
│
├── website/                       ← Docusaurus site (deployed to GitHub Pages)
│   ├── package.json
│   ├── docusaurus.config.js
│   ├── sidebars.js
│   ├── docs/                      ← the human-facing mirror of this file
│   └── src/
│
├── docs/                          ← LEGACY: superseded by website/docs/
│   └── gcp-cost-analysis/         ← KEEP: separate project (icelabz-portal)
│
└── .pi/                           ← ephemeral state (gitignored)
    └── aliyun-state.json          ← written by aliyun-smoke-test.{ps1,sh}, read by the other aliyun-* scripts
```

## 2. Opinionated architecture — the design rules

These are non-negotiable. If a future change violates one, it should be a deliberate, documented exception in the PR description.

### 2.1 Local first, cloud only when justified

The local Linux box is the primary build path because:
- $0 marginal cost.
- Fast iteration (no instance boot, no SSH round-trip).
- No rate limits or quota ceilings.

Cloud is for clean-room CI and sharing, not for everyday dev. Don't put a 5-minute turnaround on a 3-minute cloud build.

### 2.2 The warm-image pattern

**Never reinstall build dependencies on every run.** Both cloud paths create a "warm" base image once and then launch every subsequent build from that image. The cost of the warm artefact:
- DO snapshot: $0.10/GB/month, ~3-4 GB → ~$0.40/month.
- Aliyun custom image: ¥0.12/GB/month, ~8-12 GB → ~¥1/month.

Both are cheaper than one wasted build cycle.

### 2.3 Four safety nets, no exceptions

Every on-demand build script must guarantee the build instance is destroyed, even on parent process death, hard kill, network loss, or uncaught exception. The DO path has all four; the Aliyun path mirrors three of them (GH Actions #4 doesn't apply locally):

1. **`trap` for cleanup** in the shell / `try/finally` in PowerShell.
2. **Background watchdog** (nohup'd shell process / `Start-Job`) that force-deletes the instance if the parent dies.
3. **On-host bash watchdog** that calls `shutdown -h now` after `MAX_RUNTIME_MINUTES`. Catches orchestrator-unreachable.
4. **GH Actions `if: always()` cleanup step** (DO path only). Catches GH Actions runner timeouts, runner crash, network partition.

**The worst possible failure mode** is leaving a ¥15/hour build instance running overnight. The safety nets are why that doesn't happen.

### 2.4 Spot/preemptible for compute, never for storage

Both providers offer deep discounts on interruptible instances (DO: spot; Aliyun: `SpotStrategy=SpotAsPriceGo`). Use them for the build instances — a 5-minute spot reclaim mid-build is recoverable (just relaunch from the warm image, `repo sync` resumes from where it left off, and `ccache` survives).

Don't use spot for the warm image store itself — that's a custom image / snapshot, and if it gets reclaimed you've lost the 30 min of setup work.

### 2.5 Provider is a parameter, not a hard-coded choice

`do-build.sh` is provider-agnostic. The orchestrator (PowerShell for Windows, shell for macOS/Linux) is what knows about DO or Aliyun. The cloud primitives differ:
- DO has `droplet create/delete`, `snapshot create`, `compute action`.
- Aliyun has `RunInstances`, `DeleteInstance`, `CreateImage`, `StopInstance`, with VPC/vSwitch/SG/KeyPair as separate resources.

But the **shape** is the same: launch → wait → run on-host script → scp artifacts → destroy. If you ever add a third provider (Hetzner? GCP?), the existing scripts are the template.

### 2.6 State is on disk, in the repo

The Aliyun orchestrators read infra state from `.pi/aliyun-state.json`, written by `aliyun-smoke-test.{ps1,sh}`. This makes the scripts idempotent (re-runs reuse existing VPC/SG/keypair) and makes the infra visible to any agent reading the repo. The file is in `.pi/` (gitignored on purpose — see `.gitignore`).

The DO path is stateless because doctl resolves the warm snapshot by name on every run. The Aliyun path is stateful because the VPC/vSwitch/SG/KeyPair aren't discoverable by name in the same convenient way.

### 2.7 Twins: every orchestrator has both a .ps1 and a .sh

For every Windows orchestrator in `tools/`, there is a shell twin in `scripts/` (and vice versa). The two are **deliberate twins**, not "single source of truth with a wrapper": same logic, different syntax. When you change one, change the other. PRs that touch one without the other will be rejected.

Logic that should be in only one place lives in the on-host script (`tools/do-build.sh`), which is already a shell script and runs on Linux/macOS by default.

## 3. CI: what runs on every PR

The CI workflow at `.github/workflows/ci.yml` runs **static checks only**. AOSP builds are NOT run on GitHub Actions — they take 2-6 hours and would burn the free tier in a single build. AOSP builds happen locally or on the cloud fallbacks (user's own resources, not GH Actions minutes).

Six required status checks (must all pass for merge):

| Check | Tool | Scope |
| --- | --- | --- |
| `lint-powershell` | PSScriptAnalyzer | `tools/*.ps1` |
| `lint-shell` | shellcheck | `tools/*.sh`, `scripts/**/*.sh` |
| `lint-markdown` | markdownlint-cli | `**/*.md`, `**/*.mdx` |
| `secret-scan` | gitleaks | whole repo (full history) |
| `link-check` | lychee | `**/*.md` |
| `validate-manifest` | python + lxml | `default.xml`, `upstream.xml` |

To run the same checks locally, see [CONTRIBUTING.md](CONTRIBUTING.md) §"Run the local CI checks before pushing" or the CI section of the docs site.

## 4. Branch protection

`main` is protected: no PR can merge without an approved review. The exact rules (require-approvals=1, dismiss-stale-reviews, require-code-owner-reviews, linear-history, the six required status checks, etc.) are documented in [BRANCH_PROTECTION.md](BRANCH_PROTECTION.md) along with the `gh api` command to apply them. This is a GitHub-side setting; nothing in the repo enforces it directly.

## 5. Workflows

### 5.1 Local build (main flow)

```bash
sudo apt-get install -y --no-install-recommends \
    git gnupg flex bison gperf build-essential zip curl zlib1g-dev \
    gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev \
    libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip m4 bc \
    openjdk-17-jdk-headless python3 python3-pip rsync ccache jq
sudo curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    -o /usr/local/bin/repo && sudo chmod +x /usr/local/bin/repo
git config --global user.email "you@example.com" && git config --global user.name "Your Name"

mkdir -p ~/aosp && cd ~/aosp
repo init -u https://github.com/bramburn/qalos -b main
repo sync -c -j$(nproc) --no-tags --no-clone-bundle
../qalos/tools/apply-qalos.sh
. build/envsetup.sh
lunch qalos_emulator-userdebug
m -j$(nproc)
```

Full walkthrough: <https://bramburn.github.io/qalos/docs/getting-started/local-build/>

### 5.2 DigitalOcean fallback (existing)

```powershell
.\tools\doctl-install.ps1
$env:DO_API_TOKEN = '<read+write token>'
.\tools\doctl-setup-base.ps1              # one-time: warm snapshot
.\tools\doctl-build.ps1                  # on-demand build
```

GH Actions: `.github/workflows/build.yml` triggers on push to `main`, manual dispatch, or weekly Sunday 03:00 UTC smoke build.

### 5.3 Aliyun fallback (Windows)

```powershell
.\tools\aliyun-install.ps1
aliyun configure
.\tools\aliyun-smoke-test.ps1            # one-time: bootstrap VPC/SG/KeyPair
.\tools\aliyun-setup-base.ps1 -InstanceType ecs.u1-c1m8.2xlarge
.\tools\aliyun-build.ps1 -InstanceType ecs.u1-c1m8.2xlarge -MaxRuntimeMinutes 360
```

### 5.4 Aliyun fallback (macOS / Linux — .sh twins)

```bash
./scripts/aliyun-install.sh
aliyun configure
./scripts/aliyun-smoke-test.sh
./scripts/aliyun-setup-base.sh --instance-type ecs.u1-c1m8.2xlarge
./scripts/aliyun-build.sh --instance-type ecs.u1-c1m8.2xlarge --max-runtime-minutes 360
```

## 6. Cost rules

| Item | Standing | Per AOSP build |
|---|---|---|
| Local Linux box | $0 | $0 |
| DO `qalos-build-warm` snapshot | $0.40/mo | — |
| DO Spaces | $5/mo | (storage for build artifacts) |
| DO build droplet (`c-8`) | $0 | $0.50-0.80 |
| Aliyun `qalos-build-warm` custom image | ~¥1/mo | — |
| Aliyun build ECS (`u1-c1m8.2xlarge` spot, 6h) | $0 | ~¥7 |
| Aliyun egress (scp 10 GB to UK) | $0 | ~¥8 |

**Idle project cost if you only use the local box: $0.**
**Idle project cost if you maintain the DO fallback: ~$5.40/month.**
**Idle project cost if you maintain the Aliyun fallback: ~¥6/month.**

## 7. Aliyun-specific gotchas

These cost time on the first Aliyun integration. Documented so the next person doesn't re-discover them. The full list is in the [docs site](https://bramburn.github.io/qalos/docs/reference/gotchas/); the most important:

### 7.1 `DescribeInstanceTypes` ≠ in-stock

`DescribeInstanceTypes` returns the catalog; use `DescribeAvailableResource --DestinationResource InstanceType` to check zone stock. T5 burstable instances are particularly zone-limited.

### 7.2 `--InstanceType` on `DescribeAvailableResource` is unreliable as a filter

Drop the filter, get the full in-stock list, then filter in `jq` (shell) or PowerShell. The scripts already do this.

### 7.3 `DeleteInstance` on a `Running` instance can return `SDK.ServerError`

Always `StopInstance` first, wait for `Stopped`, then `DeleteInstance`. The scripts do this in the `trap`/`finally` block.

### 7.4 New accounts have a `RunInstances` rate limit

1-2 `RunInstances` per minute on day one. If you see `SDK.ServerError` after a few rapid retries, wait 60-90s. The `aliyon()` helper already retries 4 times with backoff.

### 7.5 The `aliyun` CLI suppresses error details

`ERROR: SDK.ServerError` and nothing else. Parse stdout (which is JSON), never trust the bare stderr. The `aliyon()` helper handles this.

## 8. Known limitations / open work

- **`do-build.sh` uploads to DO Spaces.** This is wrong for the Aliyun path. For now, the Aliyun orchestrator pulls artifacts via `scp` (incurs egress cost from `cn-hangzhou` to UK). The clean fix is to parameterise the upload step in `do-build.sh` with a `BUILD_UPLOAD_BACKEND=scp|spaces|oss|none` env var. Not done in this commit because it's a refactor of an existing working script.
- **No GH Actions path for Aliyun.** `.github/workflows/build.yml` is DO-only. Adding a parallel `build-aliyun.yml` is straightforward but requires GitHub secrets to be set first.
- **`docs/` legacy folder is not yet removed.** Old links may still point to `docs/local-build.md`, `docs/setup.md`, `docs/agent-brief.md`. They redirect to the new docs site (see `docs/README.md`). Will be removed in a follow-up commit.
- **Docusaurus site preview requires Node 18+ locally.** The `deploy-docs.yml` workflow handles this on the GH Actions runner. For local preview (`cd website && npm install && npm run start`), you need Node 18+ on your own machine.

## 8.1. QA Lab OS v0 followup work

The v0 of the QA Lab OS shipped on `feat/qa-lab-os-v0` (4 commits:
`4ddd890`, `59ad3e6`, `22f3cd1`, `bccbfb8`). The followup work for
v1 / Phase 2 is recorded in detail at
[`website/docs/qa-lab-os/followup-work.md`](website/docs/qa-lab-os/followup-work.md)
(human-facing mirror). The short version:

- **Bugs caught by the AOSP-15 download-and-dry-run** (all fixed in
  `fix-ups-2`, but the same review pattern caught them — see
  `website/docs/qa-lab-os/lessons-learned.md`):
  - M-A — `len(sys.argv > 1)` typo in patch 0004 → `len(sys.argv) > 1`.
  - M-B — URL-decode missing in mock `_parse_query` → added
    `urllib.parse.unquote_plus`.
  - M-C — `mActivityManager` field was dead → now used by `forceStop`
    for real `IActivityManager.forceStopPackage` (replaces the
    silently-broken `ActivityManager.killBackgroundProcesses`).
  - Patch 0001 was unnecessary because the `services.core-sources`
    filegroup's `srcs: ["java/**/*.java"]` glob already covers our
    copied `com/qalos/remotectl/*.java` → deleted.
  - Patch 0004's anchor was wrong for AOSP 15 (referenced the
    removed `traceBeginAndSlog` static method and bare `traceEnd()`)
    → rewritten to match the actual AOSP 15 pattern
    (`t.traceBegin` / `t.traceEnd` on a local `Trace t` instance).

- **Should-fix items from the v0 second-pass review**, deferred
  until v1:
  - S-A — `ActivityManager.getLaunchIntentForPackage` is deprecated
    in API 33+; migrate to `PackageManager.getLaunchIntentForPackage`.
  - S-B — `Display.getRealSize(Point)` is deprecated in API 30+;
    migrate to `WindowManager.getCurrentWindowMetrics().getBounds()`.
  - S-D — `getDisplayWidth` + `getDisplayHeight` make two Binder
    round-trips; combine into one `getDisplaySize` AIDL call.
  - S-E — `Bitmap.compress` runs on the binder thread for 100-200 ms;
    move to a worker `ExecutorService`.
  - S-F — `MotionEvent.recycle()` is also deprecated in API 28+;
    drop the call.
  - S-H — `apply-qalos.sh` silently ignores unknown flags; add a
    default arm to the case statement.
  - S-I — patch 0004's regex still requires a literal
    `InputManagerService` class name; broaden the anchor so a
    future rename does not break the patch.

- **Deferred review items** (F-1.16, F-2.3, F-2.4, F-3.3, F-3.6):
  `display_size` cache invalidation on rotation, per-client rate
  limit on `/screenshot`, structured error codes, dispatch table
  for `HttpApiServer`, `QaLabError.code` / `http_status` fields.

- **Nit items**: mixed `m`-prefix vs `_`-prefix conventions, lost
  `/* paramName */` style markers, `command -v python` fallback
  for AOSP build images that only ship `python`, etc.

- **v1 features** (per the original PRD Phase 1.5+, scoped by
  `decisions.md#d-005a`):
  - `long_press`, `swipe`, `pinch` gesture endpoints.
  - LLM agent loop template (Python skeleton) that consumes the
    agent-developer-guide pattern.
  - Multi-device orchestration helpers (the Python client is
    thread-safe; just need a barrier-sync helper).

- **Phase 2** (explicitly deferred per D-006, D-007, and the PRD's
  "What's NOT in v0" list):
  - KernelSU-Next + SuSFS kernel hiding on physical Pixel 7.
  - GPS spoofing (Smali patch on `services.jar` or custom
    `LocationProvider` HAL).
  - Play Integrity bypass (TrickyStore + keybox injection; the
    ethical-grey-zone path).
  - iOS support (XCUITest + WebDriverAgent on a Mac).
  - Sensor injection (accel / gyro / barometer) for a navigation
    test rig.

The next branch (`feat/qa-lab-os-v1`) should pull the should-fix
items and the gesture endpoints into one cohesive change. Do NOT
mix the v0 followup with new features; the diff is already non-trivial
on this side.

## 9. Tactical next steps (for whoever picks this up)

1. **If not yet done, run the Aliyun smoke test:**
   ```powershell
   .\tools\aliyun-smoke-test.ps1
   ```
   This should PASS in ~3 min. If it hangs on `RunInstances`, see §7.4 — wait 60-90 s and re-run.
2. **Create the warm image** with a real build-sized instance:
   ```powershell
   .\tools\aliyun-setup-base.ps1 -InstanceType ecs.u1-c1m8.2xlarge
   ```
3. **Kick a real AOSP build** (1-6 hours, ~¥7-14):
   ```powershell
   .\tools\aliyun-build.ps1 -InstanceType ecs.u1-c1m8.2xlarge -MaxRuntimeMinutes 360
   ```
4. **Enable GitHub Pages** for the Docusaurus site: go to repo **Settings > Pages**, select **GitHub Actions** as the source. The next push to `main` will deploy.
5. **Apply branch protection** with the `gh api` command in `BRANCH_PROTECTION.md`.
6. **Add a GH Actions path for Aliyun** by copying `.github/workflows/build.yml` to `build-aliyun.yml` and following the pattern.
7. **Refactor `do-build.sh`** to take a `BUILD_UPLOAD_BACKEND=scp|spaces|oss` env var so the Aliyun path can use OSS instead of scp.

## 10. TL;DR

- **Build locally.** 16 GB+ RAM, 200+ GB disk, Ubuntu 22.04+.
- **Cloud is a fallback.** DO has the battle-tested scripts (`doctl-*.ps1`); Aliyun is the parallel path (`aliyun-*.ps1` for Windows, `aliyun-*.sh` for macOS/Linux) for when you need a China-region run, when DO is unavailable, or when Aliyun pricing is better.
- **The on-host build is `do-build.sh`.** Both cloud paths invoke it. Don't fork it.
- **Four safety nets** prevent orphaned cloud resources. Every new build script MUST implement them.
- **The warm image is the unit of cost optimization.** Pay ~$1/month for the snapshot/image, save 30 min per build.
- **Read the gotchas (§7) before you debug Aliyun.** The CLI's error messages are useless; the gotchas are where the real signal is.
- **The docs site is at <https://bramburn.github.io/qalos/>** and is the human-facing mirror of this file. Update both when you change architecture.
