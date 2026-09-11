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
- **Three build paths:** Local Linux box (primary), DigitalOcean droplet (fallback #1), Aliyun ECS (fallback #2), GCP Compute Engine (fallback #3).
- **Cloud SSH transport:** All three cloud paths use **native SSH** to talk to the build instance. The GCP path uses Windows OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`) on the host because the gcloud SDK hardcodes PuTTY/Plink which fails against modern Linux VMs (see §7.6).
- **Single source of truth for on-host build steps:** `tools/do-build.sh`. Both cloud orchestrators invoke it.
- **Repo:** <https://github.com/bramburn/qalos> · **Docs site:** <https://bramburn.github.io/qalos/> · **License:** MIT (qalos) + Apache 2.0 (AOSP) · **Legal framework:** see [`legal/`](legal/README.md) — the licence covers copying, not use; KYC + audit logging are mandatory for any commercial distribution (see §2.9).

## 1. Folder layout

```text
qalos/
├── AGENTS.md                      ← you are here
├── README.md                      ← public-facing quickstart
├── CONTRIBUTING.md                ← PR workflow, code style, CI
├── CODE_OF_CONDUCT.md
├── BRANCH_PROTECTION.md            ← exact gh api command to apply branch protection
├── LICENSE                        ← MIT for qalos + Apache 2.0 attribution for AOSP
│
├── legal/                         ← LEGAL FRAMEWORK (use restrictions, ToS, KYC, audit, CLA, security)
│   ├── README.md                  ← the index; which doc applies to whom
│   ├── DISCLAIMER.md              ← the umbrella: no warranty, no liability for misuse
│   ├── TERMS_OF_SERVICE.md        ← the binding contract for users
│   ├── ACCEPTABLE_USE_POLICY.md   ← prohibited uses (fraud, scraping, sanctions, etc.)
│   ├── KYC.md                     ← KYC for commercial customers (prebuilt image / hosted / support)
│   ├── AUDIT_LOGGING.md           ← audit-log spec for any commercial fleet
│   ├── CLA.md                     ← Contributor License Agreement
│   └── SECURITY.md                ← vulnerability disclosure policy
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
├── tools/                         ← WINDOWS ORCHESTRATORS (.ps1) + ON-HOST (.sh) + LLM-DRIVEN DOCS
│   ├── AGENTS.md                  ← one-page index for the tools/ folder
│   ├── apply-qalos.sh             ← on-host: copy qalos content into AOSP tree
│   ├── setup-droplet.sh           ← on-host: install AOSP build deps
│   ├── do-build.sh                ← on-host: the AOSP build (single source of truth)
│   ├── aliyun/                    ← LLM-driven Aliyun build runbook
│   │   ├── AGENTS.md              ← the runbook (next agent reads this)
│   │   ├── aliyun-cli-reference.md← per-command JSON parse + error code table
│   │   ├── build-cost.md          ← per-build + standing cost table
│   │   └── qalos-serve-artifacts.py ← token-gated HTTP server for build artifacts
│   ├── doctl-*.ps1                ← DO path (Windows)
│   ├── aliyun-install.ps1         ← Aliyun CLI install (one-time)
│   ├── aliyun-smoke-test.ps1      ← Aliyun smoke test (Phase 2 of the LLM runbook; the LLM does not invoke this)
│   ├── aliyun-setup-base.ps1      ← Aliyun warm-image creation (Phase 3 of the LLM runbook)
│   └── gcp-*.ps1                  ← GCP path (Windows)
├── scripts/                       ← macOS / LINUX ORCHESTRATORS (.sh)
│   ├── aliyun-install.sh
│   ├── aliyun-smoke-test.sh
│   ├── aliyun-setup-base.sh
│   └── lib/
│       ├── aliyun-common.sh       ← aliyon(), get_state(), save_state()
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
    ├── aliyun-state.json          ← written by aliyun-smoke-test.{ps1,sh}, read by aliyun-* scripts
    └── gcp-state.json             ← written by gcp-setup-base.ps1, read by gcp-build.ps1
```text

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
- Aliyun custom image: ~¥1/GB/month at ESSD PL1, ~8-12 GB → **~¥8-12/month** (the previous ¥1/month figure was based on the deprecated snapshot-pricing tier; corrected 2026-09-09 in [`tools/aliyun/build-cost.md`](tools/aliyun/build-cost.md)).
- GCP persistent disk snapshot (pd-ssd): ~$0.10/GB/month, ~8-15 GB → ~$1-1.50/month.

All three are cheaper than one wasted build cycle. The Aliyun
warm image is the most expensive of the three because the
custom-image storage is per-GB rather than per-snapshot; if idle
cost matters, delete the image between builds (re-creating
takes ~10 min).

### 2.3 Four safety nets, no exceptions

Every on-demand build script must guarantee the build instance is destroyed, even on parent process death, hard kill, network loss, or uncaught exception. All three cloud paths (DO, Aliyun, GCP) implement all four:

1. **`trap` for cleanup** in the shell / `try/finally` in PowerShell.
2. **Background watchdog** (nohup'd shell process / `Start-Job`) that force-deletes the instance if the parent dies.
3. **On-host bash watchdog** that calls `shutdown -h now` after `MAX_RUNTIME_MINUTES`. Catches orchestrator-unreachable.
4. **GH Actions `if: always()` cleanup step** (DO path only). Catches GH Actions runner timeouts, runner crash, network partition.

**The worst possible failure mode** is leaving a ¥15/hour build instance running overnight. The safety nets are why that doesn't happen.

### 2.4 Spot/preemptible for compute, never for storage

Both providers offer deep discounts on interruptible instances (DO: spot; Aliyun: `SpotStrategy=SpotAsPriceGo`; GCP: `provisioning-model=SPOT`). Use them for the build instances — a 5-minute spot reclaim mid-build is recoverable (just relaunch from the warm image, `repo sync` resumes from where it left off, and `ccache` survives). GCP Spot VMs have a 30-second preemption notice. Use `--spot-instance-max-run-duration` to cap the maximum runtime.

Don't use spot for the warm image store itself — that's a custom image / snapshot / persistent disk, and if it gets reclaimed you've lost the 30 min of setup work.

### 2.5 Provider is a parameter, not a hard-coded choice

`do-build.sh` is provider-agnostic. The orchestrator (PowerShell for Windows, shell for macOS/Linux) is what knows about DO, Aliyun, or GCP. The cloud primitives differ:
- DO has `droplet create/delete`, `snapshot create`, `compute action`.
- Aliyun has `RunInstances`, `DeleteInstance`, `CreateImage`, `StopInstance`, with VPC/vSwitch/SG/KeyPair as separate resources.
- GCP has `instances create/delete`, `instances stop`, `snapshots create`, managed via `gcloud compute`.

But the **shape** is the same: launch → wait → run on-host script → pull artifacts → destroy. If you ever add a fourth provider (Hetzner? Azure?), the existing scripts are the template.

### 2.6 State is on disk, in the repo

The Aliyun orchestrators read infra state from `.pi/aliyun-state.json`, written by `aliyun-smoke-test.{ps1,sh}`. The GCP orchestrator reads `.pi/gcp-state.json`, written by `gcp-setup-base.ps1`. This makes the scripts idempotent and makes the infra visible to any agent reading the repo. Both files are in `.pi/` (gitignored — see `.gitignore`).

The DO path is stateless because doctl resolves the warm snapshot by name on every run. The Aliyun path is stateful because the VPC/vSwitch/SG/KeyPair aren't discoverable by name in the same convenient way. The GCP path is also stateless — `gcloud compute snapshots list` resolves the snapshot by name on every run, like DO.

### 2.7 Twins: every orchestrator has both a .ps1 and a .sh

For every Windows orchestrator in `tools/`, there is a shell twin in `scripts/` (and vice versa). The two are **deliberate twins**, not "single source of truth with a wrapper": same logic, different syntax. When you change one, change the other. PRs that touch one without the other will be rejected.

Logic that should be in only one place lives in the on-host script (`tools/do-build.sh`), which is already a shell script and runs on Linux/macOS by default.

### 2.8 Long-running builds are LLM-monitored, not script-monitored

AOSP builds take 1-6 hours. The orchestrator script (`.ps1` / `.sh`) is **synchronous** and only lives as long as the process that invoked it. A bare script invocation in CI, a scheduled task, or a different agent without `mavis` tools would create a cron it can't manage.

The convention: the **LLM** (mavis) sets up the monitor cron, NOT the script. After the orchestrator reports `instance created: qalos-build-...`, the driving LLM should call `mavis cron create --schedule "*/10 * * * *" --cron_name "qalos-build-<instanceName>" --prompt "<watchdog prompt>" --session '{"mode":"sessionId","sessionId":"<this-session-id>"}'`.

The script stays focused on what it does well (create / run / cleanup). The LLM stays focused on what it does well (cross-session state, cron lifecycle, smart decisions, artifact download via HTTP). Both pieces have explicit fallbacks: the script works without the LLM (just no monitor), and the LLM works without the script (manually re-runs and reads the same prompts).

This rule applies to all three cloud paths: gcp / aliyun / DO.

**As of 2026-09-09 the Aliyun path is fully LLM-driven.** The
`tools/aliyun-build.ps1` and `scripts/aliyun-build.sh` orchestrators
were **removed** (mavis-trash) on 2026-09-09 — they had three
known bugs (B-1: `$ddidx` typo in the wait loop; B-2: missing
`$sgId`/`$vswId` load from the state file; B-3: blocking on
SSH for 1-6 hours, the same shape that bit the GCP path on
2026-09-04). The replacement is the LLM-driven runbook at
[`tools/aliyun/AGENTS.md`](tools/aliyun/AGENTS.md), where the
agent calls `aliyun ecs ...` directly via Bash, starts the
build as a detached `systemd-run` unit, and sets up the
`mavis cron` in the same turn. The smoke test and setup-base
scripts (which don't have the SSH-blocking bug) remain on
disk for users who prefer scripts. See
[`tools/AGENTS.md`](tools/AGENTS.md) for the index.

### 2.9 The legal framework is non-negotiable

Used for QA testing, it is benign. Used for fake-account creation,
ad fraud, credential stuffing, or bulk scraping, it is harmful and
may be illegal.

The legal framework in [`legal/`](legal/README.md) is the project's only
defence against the second case — the source is public, the build
is reproducible, and there is no technical "fuse" that prevents
misuse. The framework therefore imposes **mandatory** process
controls (KYC, audit logging) on any commercial distribution, and
**explicit** use restrictions (the AUP) on every user.

**Non-negotiables:**

1. **KYC is mandatory for commercial distribution.** Anyone who
   receives a prebuilt image, hosted service, or commercial
   support goes through the KYC process in [`legal/KYC.md`](legal/KYC.md).
   No exceptions. The alternative is the project becoming an
   attractive nuisance for fraud.
2. **Audit logging is mandatory for any commercial fleet.** The
   spec in [`legal/AUDIT_LOGGING.md`](legal/AUDIT_LOGGING.md) is
   the minimum; the `RemoteControlService` in
   `packages/apps/RemoteControlService/` is intended to implement
   the event-capture part natively. A device that runs a prebuilt
   image in a commercial context MUST keep an audit log.
3. **The AUP cannot be relaxed by a PR.** The list in
   [`legal/ACCEPTABLE_USE_POLICY.md`](legal/ACCEPTABLE_USE_POLICY.md)
   is the floor. Adding a new permitted use requires a documented
   PR that explicitly addresses the new use case against the
   framework principles (fraud risk, regulator exposure, audit-log
   sufficiency).
4. **Contributors accept the CLA.** The CLA in [`legal/CLA.md`](legal/CLA.md)
   is accepted by conduct (submitting a PR). The CLA is the
   project's only defence against an IP-claim from a third party
   about a contribution.
5. **Material changes to the legal framework require a release
   note.** A change to a legal document is a breaking change for
   users who have accepted the prior version. PRs that change a
   legal document MUST add a release-note entry and, for
   commercial customers, MUST trigger a direct-notice workflow.
6. **The legal framework is DRAFT.** Every document in `legal/`
   carries a "DRAFT — not legal advice" banner. None of it has
   been reviewed by a solicitor. A PR that moves any of the
   documents out of DRAFT status MUST include a confirmation from
   a solicitor (or a link to a PR that adds such a confirmation
   to the project record).

**Trigger to escalate the legal framework:** if a regulatory
development (UK Online Safety Act, EU AI Act, US state-level bot
disclosure, a court ruling on open-source liability) materially
changes the risk profile of the project, the framework must be
reviewed and updated, and the update must be communicated to all
known commercial customers.

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
# Use lower concurrency for `repo sync` than for the AOSP build: the git
# fetches hit `android.googlesource.com` which has per-IP rate limits, and
# running 16 parallel git fetch processes gets RESOURCE_EXHAUSTED / HTTP 429
# errors on a few of the ~1500 repos. -j8 finishes in roughly the same wall
# time (downloads are bandwidth-bound, not CPU-bound). On the cloud paths
# this is handled by `do-build.sh` (REPO_SYNC_JOBS=8 default with 3 retries
# and exponential backoff, falls back to -j1 --fail-fast on persistent failure).
repo sync -c -j8 --no-tags --no-clone-bundle
../qalos/tools/apply-qalos.sh
. build/envsetup.sh
lunch qalos_emulator-userdebug
m -j$(nproc)
```text
Full walkthrough: <https://bramburn.github.io/qalos/docs/getting-started/local-build/>

### 5.2 DigitalOcean fallback (existing)

```powershell
.\tools\doctl-install.ps1
$env:DO_API_TOKEN = '<read+write token>'
.\tools\doctl-setup-base.ps1              # one-time: warm snapshot
.\tools\doctl-build.ps1                  # on-demand build
```text
GH Actions: `.github/workflows/build.yml` triggers on push to `main`, manual dispatch, or weekly Sunday 03:00 UTC smoke build.

### 5.3 Aliyun fallback

**As of 2026-09-09, the Aliyun path is LLM-driven, not script-driven.**
The LLM agent reads [`tools/aliyun/AGENTS.md`](tools/aliyun/AGENTS.md) and
calls the Aliyun CLI directly via the Bash tool. The PS1 build
script (`tools/aliyun-build.ps1`) and its `.sh` twin
(`scripts/aliyun-build.sh`) were **removed** on 2026-09-09 — they
had three known bugs (B-1, B-2, B-3) that blocked first-run use
and a control flow that could delete a healthy build if the SSH
connection dropped. The smoke test and setup-base scripts
remain on disk for users who prefer scripts (they don't have
the SSH-blocking bug).

> **🚨 READ [`tools/aliyun/LESSONS.md`](tools/aliyun/LESSONS.md) FIRST.**
> The 2026-09-10 build series burned ~¥20 across 5 failed attempts
> because we didn't know: (1) Aliyun `cn-hangzhou` ECS is on a
> closed network and cannot reach any AOSP mirror (TUNA, USTC,
> Aliyun itself are all blocked or fake), (2) transfer speed from
> any source to the Aliyun ECS is 2-3 MB/s, and (3) AOSP 15 needs
> `g7a.16xlarge` (256 GB RAM), not `g7a.2xlarge` (32 GB). LESSONS.md
> documents the decision tree for the next attempt and the
> `do-build.sh` fixes that are still valid.

The one-time install is the same:

```powershell
.\tools\aliyun-install.ps1
aliyun configure
```

Then the LLM reads [`tools/aliyun/AGENTS.md`](tools/aliyun/AGENTS.md) and
runs the four phases (smoke test → warm image → sync+preflight
→ full build). Each phase is a sequence of `aliyun ecs ...`
Bash invocations; the LLM also sets up a `mavis cron` that owns
teardown. The build artifacts are downloaded over HTTP (via
`curl` or a browser) using the token-gated URL the systemd
unit's `ExecStartPost=` writes — see the runbook's
"Downloading artifacts" section.

**Per-build state file** — the LLM-driven Phase 4 flow maintains
`D:\qalos\.pi\aliyun-build-state.json` (schema
`qalos://aliyun-build-state/v1`, documented in
[`tools/aliyun/AGENTS.md`](tools/aliyun/AGENTS.md) §"Per-build state
file"). Separate from the INFRA state file
(`.pi/aliyun-state.json`); the build file tracks one attempt
(status, instance, SSH, artifact URL, mavis cron ID, decisions,
state transitions, recovery actions). The mavis cron and any
follow-up agent read it. Do not delete it until the instance is
`torn_down`; archive it under a timestamped name if you want to
keep the build history.

The remaining PS1-driven flow (kept for users who prefer scripts
for the smoke test and warm image only):

```powershell
.\tools\aliyun-smoke-test.ps1            # one-time: bootstrap VPC/SG/KeyPair
.\tools\aliyun-setup-base.ps1 -InstanceType ecs.u1-c1m8.2xlarge
```text

The actual build is LLM-driven only; the removed
`aliyun-build.ps1` is not replaced by a script.

### 5.4 Aliyun fallback (macOS / Linux — .sh twins)

The macOS/Linux `.sh` twins of `aliyun-install.sh`,
`aliyun-smoke-test.sh`, and `aliyun-setup-base.sh` remain on
disk for users who prefer scripts. The `.sh` twin of the build
script (`scripts/aliyun-build.sh`) was **removed** alongside
its `.ps1` sibling on 2026-09-09 — the build is LLM-driven only.

```bash
./scripts/aliyun-install.sh
aliyun configure
./scripts/aliyun-smoke-test.sh
./scripts/aliyun-setup-base.sh --instance-type ecs.u1-c1m8.2xlarge
# build: LLM reads tools/aliyun/AGENTS.md and calls aliyun ecs ... directly
```text

### 5.4.1 Aliyun account identity & known blockages (added 2026-09-11)

**Verified working identity (do NOT confuse with the local Ubuntu username):**

| Item | Value |
| --- | --- |
| Account ID | `<redacted — see user-private config>` |
| RAM user (full FQN) | `<redacted — see user-private config>` |
| Display name | `aliyun-cli-user` |
| AccessKey ID | `<redacted — see ~/.bashrc on macmini2024>` |
| AccessKey Secret | (in `~/.bashrc` on `macmini2024`, AKA `192.168.0.46`, and in `~/.aliyun/config.json`) |
| Default region | `cn-guangzhou` |

**Stored on `macmini2024`** in `~/.bashrc` and `~/.profile`:

```bash
export ALIYUN_RAM_USER="<redacted — see ~/.bashrc on macmini2024>"
export ALIYUN_ACCOUNT_ID="<redacted — see ~/.bashrc on macmini2024>"
```

These are exported as non-interactive env vars so any agent that lands on the Mac Mini can immediately grant or check this user's permissions in the Aliyun console (https://ram.console.aliyun.com/users/aliyun-cli-user/identity).

**Windows-side `aliyun configure list` shows a different AK (`...ZGd`).** That AK belongs to a different sub-user. Do not use it for qalos work — use the BH8 AK from `~/.bashrc` on `macmini2024` or from the user's private AccessKey.csv (not committed).

### 5.4.2 Known OSS blockage: public endpoint disabled at account level (2026-09-11)

This Aliyun account has **OSS data operations blocked on the public endpoint** from outside China. Symptom:

```
Error: operation error PutObject: Error returned by Service.
Http Status Code: 400.
Error Code: PublicEndpointForbidden.
Message: Not allowed using the OSS public endpoint , please use CNAME instead.
EC: 0003-00000801 (for CreateBucket when RAM user is disabled) / 0048-00000401 (for PUT/LIST).
```

Bucket management (`mb`, `stat`, `get-acl`) works fine. `ossutil cp` and `ossutil ls` against any prefix fail with this error.

**Workaround that was proven on 2026-09-11:** skip OSS as the staging layer entirely and upload directly from `macmini2024` (UK) to a small ECS receiver in `cn-guangzhou` over SSH. Concrete recipe:

1. Create the receiver ECS (Ubuntu 24.04, `ecs.u1-c1m2.large` is fine, public IP required):
   ```bash
   aliyun ecs RunInstances --RegionId cn-guangzhou \
     --ImageId ubuntu_24_04_x64_20G_alibase_<YYYYMMDD>.vhd \
     --InstanceType ecs.u1-c1m2.large \
     --VSwitchId vsw-7xvvy64syomut0vdu6iin \
     --SecurityGroupId sg-7xv0xvsywi6cm82ea65c \
     --KeyPairName qalos-aosp-key-ed25519 \
     --InstanceChargeType PostPaid \
     --InternetChargeType PayByTraffic --InternetMaxBandwidthOut 100 \
     --SystemDisk.Category cloud_essd --SystemDisk.Size 40
   ```
2. Resize the system disk to ≥300 GB **while stopped** (online resize fails for this image; need `StopInstance` → `ResizeDisk` → `StartInstance`), then SSH in and run `growpart /dev/vda 3 && resize2fs /dev/vda3`.
3. SSH the receiver from `macmini2024`, install `p7zip-full`.
4. Upload via rsync (resumable):
   ```bash
   rsync -av --progress --partial --inplace \
     -e 'ssh -i ~/.ssh/id_ed25519_qalos -o StrictHostKeyChecking=no -o ServerAliveInterval=30' \
     ~/aosp_volumes/ root@<ECS_IP>:/aosp/
   ```

Expected wall time for 34 GB: 2–10 hours depending on UK home upstream.

### 5.4.4 UK → cn-guangzhou SSH is DPI-throttled (2026-09-11, added after the §5.4.2 recipe failed)

**Do NOT trust the 2-10 hour estimate above.** On 2026-09-11 the actual measured throughput was ~1-12 KB/s — a 64-minute rsync transferred only 5.3 MB of 100 MB (~1.4 KB/s avg), and a 5 MB scp test hung past the 120s timeout. At that rate, 34 GB would take 281 days.

**Symptoms:**
- TCP handshake to cn-guangzhou ECS port 22: ✅ fast (0.26s)
- SSH auth / key exchange: ✅ works
- Bulk data on port 22: ❌ ~1-12 KB/s sustained, parallel streams don't help

**Diagnosis:** Looks like GFW DPI throttling per-flow SSH data once it detects a sustained large transfer. The throttle is per-connection, not total bandwidth — running 4 parallel rsyncs didn't increase throughput.

**Workaround that actually works:** don't use port 22 / SSH for the bulk hop. Upload from UK to a non-throttled HTTPS intermediate (Cloudflare R2, Backblaze B2, AWS S3, GitHub Releases — anything on port 443) which is typically unthrottled. Then download from the intermediate to the cn-guangzhou ECS either from inside cn-hongkong (free, fast) or by relaying through an HK VPS. Total wall time drops from "unusable" to ~3-4 hours.

**Verification step before committing to a transfer:** always run a 5 MB scp speed test first. If throughput is <100 KB/s, abort and pick a different path — don't waste hours hoping it'll improve.

**Long-term fix:** ask Aliyun support to either (a) lift the public-endpoint block on the account, or (b) document the CNAME record they want us to use. Until then, the direct-ECS path above is the only one that works.

### 5.4.3 RAM user state traps (2026-09-11)

Two distinct failure modes both look like permission problems but need different fixes:

1. **`UserDisable` (HTTP 403, code `0003-00000801`) on `CreateBucket`** — the RAM user has policies attached but is **Disabled**. Fix: go to https://ram.console.aliyun.com/users/aliyun-cli-user/identity and click **Enable User**. (The "User Status" field is NOT in the Authentication sub-tab — it's on the user detail page Basic Information section or the Users list kebab menu.)

2. **`AccessDenied` (HTTP 403, code `Unauthorized`) on `ListBuckets` or other OSS ops** — the user is enabled but has no policy. Fix: attach the system policy `AliyunOSSFullAccess` to the user.

If you can `ossutil ls` (returns `Bucket Number is: 0`) but `ossutil mb` fails with `UserDisable`, you are in case (1), not case (2).

### 5.4.5 HK OSS relay pattern: the recipe that actually works (2026-09-11)

The §5.4.2 recipe (direct SSH from UK to cn-guangzhou) does NOT
work in practice — see §5.4.4. The §5.4.4 generic workaround
(any HTTPS intermediate, then download from HK) was refined on
2026-09-11 into a concrete, end-to-end working pattern. This
section is the recipe.

**Topology:**

```
macmini2024 (UK, 192.168.0.46)
       │  ossutil cp via oss-cn-hongkong.aliyuncs.com (port 443)
       │  9.4 MiB/s avg, 60 min for 35.5 GB
       ▼
┌─────────────────────────────────────┐
│  HK OSS bucket qalos-aosp-hk        │
│  cn-hongkong (endpoint public OK)   │
└─────────────────────────────────────┘
       │  ossutil cp via oss-cn-hongkong-internal.aliyuncs.com
       │  109 MiB/s, 5 min for 35.5 GB  (intra-region, free)
       ▼
┌─────────────────────────────────────┐
│  HK ECS i-j6c13vpnkuq5dwj92rvc      │
│  cn-hongkong-d, 47.238.148.200      │
│  ecs.u1-c1m2.large, 300 GB disk     │
└─────────────────────────────────────┘
       │  cat aosp.zst.* | zstd -d | tar -xf -
       │  Extracts 35 GB → 127 GB AOSP source (~40-75 min on 2 vCPU)
       ▼
       StopInstance → CreateImage (custom image m-xxx in cn-hongkong)
       → CopyImage --DestinationRegionId cn-guangzhou (image m-yyy in cn-guangzhou)
       → RunInstances from m-yyy with ecs.u1-c1m8.2xlarge or larger
```

**Why this works:**

1. **HK's public OSS endpoint is not blocked** like cn-guangzhou's.
   This Aliyun account can `ossutil cp` to `oss-cn-hongkong.aliyuncs.com`
   without hitting `PublicEndpointForbidden`. (cn-guangzhou's public
   endpoint is blocked at the account level — see §5.4.2.)
2. **HK internal OSS endpoint is free and 5× faster** than the public
   one. Using `oss-cn-hongkong-internal.aliyuncs.com` from inside
   HK is on Aliyun's internal backbone — no internet egress charge,
   100+ MB/s for parallel multipart downloads.
3. **HK OSS → HK ECS download is intra-region, no DPI**, no SSH
   port-22 throttling, no public-endpoint block. 35.5 GB lands
   in 5 minutes.
4. **HK ECS can run `do-build.sh`** — same way as cn-guangzhou would,
   but you don't have to ship the source tree from UK to cn-hangzhou
   over a 1 KB/s throttled SSH pipe. You build the image in HK
   and then `CopyImage` it to cn-guangzhou for the production build.

**Concrete commands (verified end-to-end 2026-09-11):**

```bash
# One-time: create HK infra (VPC, VSwitch, SG, KeyPair, OSS bucket).
# State is in .pi/aliyun-state.json after aliyun-smoke-test.{ps1,sh}.
# HK specifics: cn-hongkong-d zone, qalos-aosp-hk bucket.

# Upload (Mac Mini → HK OSS public endpoint).
# 35.5 GB, 339 files, ~60 min at 9.4 MiB/s avg.
ossutil cp -r --jobs 8 --update ~/aosp_volumes/ \
    oss://qalos-aosp-hk/aosp-source/ \
    --endpoint oss-cn-hongkong.aliyuncs.com

# Download (HK OSS internal endpoint → HK ECS).
# 35.5 GB, 339 files, ~5 min at 110 MiB/s.
# Must run from inside the HK ECS:
ossutil cp -r --jobs 8 --update oss://qalos-aosp-hk/aosp-source/ \
    /aosp/ \
    --endpoint oss-cn-hongkong-internal.aliyuncs.com

# Extract (on HK ECS). See §7.10 for why this is three phases, not one pipe.
cat /aosp/aosp.zst.* > /aosp/aosp.tar       # Phase 1: ~12 min on 2 vCPU
zstd -d /aosp/aosp.tar -o /aosp/aosp.tar.raw   # Phase 2: ~30-60 min
tar -xf /aosp/aosp.tar.raw -C /aosp-extracted/ # Phase 3: ~5-10 min

# Snapshot the extracted source.
aliyun ecs StopInstance --RegionId cn-hongkong --InstanceId i-j6c13vpnkuq5dwj92rvc
aliyun ecs CreateImage --RegionId cn-hongkong \
    --InstanceId i-j6c13vpnkuq5dwj92rvc \
    --ImageName qalos-aosp-base-v1 \
    --Description "AOSP 15.0.0_r1 source tree, ready for build"

# Copy the image to cn-guangzhou for the production build VM.
aliyun ecs CopyImage --RegionId cn-hongkong \
    --ImageId m-xxxxxxxxx \
    --DestinationRegionId cn-guangzhou \
    --DestinationImageName qalos-aosp-base-v1

# Launch the build VM from the copied image.
aliyun ecs RunInstances --RegionId cn-guangzhou \
    --ImageId m-yyyyyyyyy \
    --InstanceType ecs.u1-c1m8.2xlarge \
    --InstanceChargeType PostPaid --SpotStrategy SpotAsPriceGo \
    --VSwitchId vsw-7xvvy64syomut0vdu6iin \
    --SecurityGroupId sg-7xv0xvsywi6cm82ea65c \
    --KeyPairName qalos-aosp-key-ed25519 \
    --SystemDisk.Category cloud_essd --SystemDisk.Size 500
```

**Timing summary (measured 2026-09-11):**

| Phase | Throughput | Wall time for 35.5 GB → 127 GB |
| --- | --- | --- |
| Mac Mini → HK OSS (public) | 9.4 MiB/s | 60 min |
| HK OSS → HK ECS (internal) | 109 MiB/s | 5 min |
| HK ECS: cat 339 volumes | ~50 MB/s | 12 min |
| HK ECS: zstd decompress | single-threaded | 30–60 min |
| HK ECS: tar extract | disk-bound | 5–10 min |
| CreateImage + CopyImage | Aliyun API | 10–30 min |
| **Total** | | **~2.5–3.5 hours** |

### 5.4.6 Why HK over Singapore (cost & speed, 2026-09-11)

The user explicitly asked for HK over Singapore because HK
is cheaper. Per-instance spot prices on
`ecs.u1-c1m2.large` (the small receiver ECS):

| Region | Spot price (USD/hr) | Notes |
| --- | --- | --- |
| cn-hongkong | ~$0.015 | Cheapest; egress to cn-guangzhou is free |
| ap-southeast-1 (Singapore) | ~$0.020 | 30% more |
| cn-guangzhou | n/a | public OSS endpoint blocked at account level |
| cn-shanghai | ~$0.015 | Could work but no proven recipe |

For the small HK ECS that runs for ~2 hours during extraction,
the difference is $0.015 × 2 vs $0.020 × 2 = $0.01. The real
saving is on the `CopyImage` transfer (intra-region is free,
inter-region is ~¥0.08/GB) and the fact that HK's public OSS
endpoint isn't blocked.

**Don't assume Singapore would be a drop-in substitute.** The
public-endpoint block in §5.4.2 is documented for cn-guangzhou;
ap-southeast-1's public endpoint behavior on this account is
**not** verified. Before switching, run a 5 MB `ossutil cp` test
from `macmini2024` first.

### 5.5 GCP fallback (Windows)

```powershell
.\tools\gcp-install.ps1                    # one-time: verify gcloud + auth
.\tools\gcp-smoke-test.ps1                 # optional: validate create+SSH+delete (~1 min, ~$0.004)
.\tools\gcp-setup-base.ps1                 # one-time: warm snapshot (~10 min)
.\tools\gcp-build.ps1                     # on-demand build (LLM should set up the monitor cron after)
.\tools\gcp-build.ps1 -InstanceType c3d-standard-16  # 64 GB RAM if c3d-highcpu-16 OOMs
.\tools\gcp-build.ps1 -MaxRuntimeMinutes 360 -KeepOnFailure  # debug: leave instance up
.\tools\gcp-build.ps1 -NetworkTier PREMIUM          # default is STANDARD; PREMIUM = Google's tier-1 backbone
```text

> **⚠️ `gcp-build.ps1` SSH-shutdown bug (DO NOT USE for builds > 10 min)**
>
> The `gcp-build.ps1` script's SSH call into the instance has a known shutdown-detection bug: when the remote `do-build.sh` process tree exits, the parent SSH session does not always close promptly. The script then sits "waiting" for **up to 4 hours**, until the SSH connection eventually drops for some other reason. At that point the script's `try/finally` block runs and **unconditionally stops and deletes the instance** — even if the build itself is healthy and was running via a separate `systemd-run` unit on the same instance.
>
> **Concrete 2026-09-04 incident:** `qalos-build-20260904-180634` was at 45% (`BUILD_RUNNING`, compiling libLLVM AArch64) for 4 hours, then the gcp-build.ps1 background task finally exited and deleted the instance. All 4 hours of compile progress were lost.
>
> **The correct pattern** for any AOSP build on GCP (1-6 hours):
>
> 1. `gcp-build.ps1` may create the instance and upload files, but should NOT own the cleanup.
> 2. The build itself must be launched via `systemd-run --unit=qalos-resumeN` (or equivalent detached unit) on the instance, so it survives gcp-build.ps1's eventual exit.
> 3. The **LLM monitor cron is the single owner of `gcloud compute instances delete`** — not the script (see "Build monitor (cron) — LLM-driven, not script-driven" below). The cron's step 6 is: "After downloads: `gcloud compute instances delete qalos-build-NAME --zone=Z --quiet` if present."
> 4. The proper long-term fix is patching `gcp-build.ps1` to remove the unconditional `try/finally` delete, or to add a `-NoAutoDelete` switch that the LLM can use when it wants the cron to own cleanup.
>
> **TL;DR:** for any build longer than ~10 min, treat `gcp-build.ps1` as a "create + upload" tool only, not a "wait for build" tool. Launch the actual build via `systemd-run` on the instance, and have the LLM monitor cron own the instance teardown.

**Cheapest viable machine:** `c3d-highcpu-16` Spot (16 vCPU, 32 GB, ~$0.13/hr) in `us-central1`. If the Java compile OOMs, upgrade to `c3d-standard-16` Spot (16 vCPU, 64 GB, ~$0.15/hr). Spot can be reclaimed with 30-second notice — `repo sync` is resumable and `ccache` survives a reclaim, so a mid-build preemption adds one retry round at worst.

**Network tier:** `-NetworkTier STANDARD` (default) routes egress through the public internet at ~$0.02/GB. `-NetworkTier PREMIUM` uses Google's tier-1 backbone at ~$0.08/GB but is faster and more reliable. For AOSP builds, the bulk of network traffic is `repo sync` from `android.googlesource.com` which is **inside Google's network and free regardless of tier** — so the tier mostly affects the final `scp` of artifacts back to the orchestrator (1-5 GB). Default to STANDARD; switch to PREMIUM if you see flaky network or you need the lower latency to Google's services.

**SSH transport:** the GCP scripts use `C:\Windows\System32\OpenSSH\ssh.exe` directly (not `gcloud compute ssh`). See §7.6. The script reads the public key from `%USERPROFILE%\.ssh\google_compute_engine` (generated on first `gcloud compute ssh` invocation) and uses the local Windows username (`$env:USERNAME`); the GCP guest agent auto-creates that user on the instance and drops the public key into its `~/.ssh/authorized_keys`.

**Build monitor (cron) — LLM-driven, not script-driven:** AOSP builds take 1-6 hours; an LLM session rarely sits with the user the whole time. The convention is: the **LLM** (mavis) sets up the monitor cron, NOT the script. A bare `.ps1` invocation (CI, scheduled task, another agent without `mavis` tools) shouldn't create crons it can't manage. After `gcp-build.ps1` reports `instance created: qalos-build-...`, the driving LLM should call:

```text
mavis cron create \
    --cron_name "qalos-build-<instanceName>" \
    --schedule "*/10 * * * *" \
    --prompt "<the prompt template from the end of this section>" \
    --session '{"mode":"sessionId","sessionId":"<this-session-id>"}'
```text
The cron ticks every 10 min, SSHes in for a one-liner status, and when the build finishes downloads the build log, all 5 image files, and the serial console output to `.pi/out/gcp-build/<instanceName>/`. It also `mavis cron delete`s itself once done or after 6 hours.

This convention applies to all three cloud paths: gcp / aliyun / DO. The script stays focused on what it does well (create / run / cleanup); the LLM stays focused on what it does well (cross-session state, cron lifecycle, smart decisions).

**Logging via gcloud CLI** — when investigating a failed build:

| What | Command | When useful |
|---|---|---|
| Serial console (boot, kernel, watchdog) | `gcloud compute instances get-serial-port-output <name> --zone=us-central1-a --port=1 --start=-1048576` | Boot failures, kernel panics, watchdog shutdown, why an instance won't come up. The script captures this automatically on every build to `<ArtifactDownloadDir>\serial-console.log` (the last 1 MB of the serial buffer). |
| Build log | `<ArtifactDownloadDir>\build.log` (downloaded by the monitor cron) or `tail -f` via SSH | AOSP build errors, Java heap OOMs, missing tools |
| Repo sync log | `~/aosp/.qalos-logs/repo-sync.log` on the instance | Network errors during `repo sync` |
| Cloud Logging | `gcloud logging read 'resource.type=gce_instance AND resource.labels.instance_id=<id>' --limit=50` | syslog + agent logs forwarded to Cloud Logging. Requires the Ops Agent to be installed on the instance (not done by `setup-droplet.sh`; install with `gcloud compute instances ops-agents policy create ...` if you want this). |
| Spot preemption notice | `gcloud compute operations list --filter="operationType=compute.instances.preempted"` | Was the instance killed by Spot reclaim? |

## 5.5. Two-hop AOSP sync via Linux box (Aliyun workaround)

Aliyun ECS in cn-hangzhou **cannot reach** `android.googlesource.com`, `gerrit.googlesource.com`, `storage.googleapis.com`, or GitHub — it is behind China's firewall. The workaround: a Linux box on the open internet acts as the AOSP source gateway.

**One-time SSH key setup (from Windows):**

```powershell
# 1. Generate key pair (one-time)
ssh-keygen -t ed25519 -C "bramburn@windows" -f "$env:USERPROFILE\.ssh\id_ed25519_qalos"

# 2. Install public key on the Linux box (password auth needed once here)
Get-Content "$env:USERPROFILE\.ssh\id_ed25519_qalos.pub" | ssh bramburn@192.168.0.45 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# 3. Verify passwordless login
ssh -i "$env:USERPROFILE\.ssh\id_ed25519_qalos" bramburn@192.168.0.45 "echo OK"
```

**Sync workflow (one command on the Linux box):**

```bash
# Run on the Linux box (192.168.0.45) as the user who has open internet:
mkdir -p ~/aosp && cd ~/aosp
repo init -u https://github.com/bramburn/qalos -b main
repo sync -c -j8 --no-tags --no-clone-bundle
# Then tar and scp to Aliyun ECS:
tar -czf /tmp/qalos-aosp.tar.gz . --exclude='.repo' --exclude='.git'
scp /tmp/qalos-aosp.tar.gz <aliyun-user>@<aliyun-ip>:/path/to/aosp.tar.gz
```

**Why this works:** Aliyun ECS can **receive** inbound connections from anywhere — it just can't initiate outbound to Google. The Linux box pushes the synced source to Aliyun over SSH.

## 6. Cost rules

| Item | Standing | Per AOSP build |
|---|---|---|
| Local Linux box | $0 | $0 |
| DO `qalos-build-warm` snapshot | $0.40/mo | — |
| DO Spaces | $5/mo | (storage for build artifacts) |
| DO build droplet (`c-8`) | $0 | $0.50-0.80 |
| Aliyun `qalos-build-warm` custom image (8-12 GB ESSD PL1) | **~¥8-12/mo** (corrected 2026-09-09) | — |
| Aliyun build ECS (`g7a.16xlarge` spot, 1.5 h) | $0 | ~¥9 (compute + disk + egress) |
| Aliyun egress (scp 3 GB to UK) | $0 | ~¥0.4 (only 3 GB; not 10) |
| GCP `qalos-build-warm` snapshot (incremental, ~1 GB actual data on 200 GB disk) | ~$0.03/mo | — |
| GCP build (`c3d-highcpu-16` Spot, 6h, us-central1) | $0 | ~$0.76 |
| GCP build (`c3d-standard-16` Spot, 6h, us-central1) | $0 | ~$0.92 |

**Idle project cost if you only use the local box: $0.**
**Idle project cost if you maintain the DO fallback: ~$5.40/month.**
**Idle project cost if you maintain the Aliyun fallback: ~¥8-12/month** (was quoted as ~¥6/month; corrected — the warm image at ESSD PL1 ¥1/GB/month on 8-12 GB is ¥8-12, not ¥1).
**Idle project cost if you maintain the GCP fallback: ~$0.03/month (warm snapshot is incremental — only ~1 GB of actual data, not the full 200 GB disk).**

See [`tools/aliyun/build-cost.md`](tools/aliyun/build-cost.md) for
the full Aliyun cost breakdown and the cost-scaling tips.

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

### 7.6 GCP `gcloud compute ssh` uses PuTTY/Plink on Windows and fails against modern Linux

**The hardcoded Plink path:** `C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\lib\googlecloudsdk\command_lib\util\ssh\ssh.py:206-210`. As of SDK 583.0.0 (core 2026.08.31) it's still PuTTY-on-Windows, hardcoded. Two symptoms:

1. **IAP tunneling fails**: `gcloud compute ssh --tunnel-through-iap ...` → Plink's TLS handshake to `tunnel.googleapis.com:443` is rejected with "Remote side unexpectedly closed network connection". Affects Windows hosts behind corporate firewalls, TLS-inspection proxies, or where Plink's TLS version mismatch doesn't match the IAP proxy.
2. **Direct SSH fails against Debian 12 / OpenSSH 8.8+**: "Server refused public-key signature despite accepting key! (server sent: publickey)". Plink 0.83's SHA-1 RSA signature isn't in the server's `PubkeyAcceptedAlgorithms`. Affects every modern Linux distro: Debian 12, Ubuntu 22.04+, RHEL 9, etc.

**Why the build scripts don't use `gcloud compute ssh`:** both errors above manifest in any gcloud-based SSH call. The orchestrator scripts (`gcp-smoke-test.ps1`, `gcp-setup-base.ps1`, `gcp-build.ps1`) instead call Windows OpenSSH directly:

```powershell
& 'C:\Windows\System32\OpenSSH\ssh.exe' -i "$env:USERPROFILE\.ssh\google_compute_engine" `
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
    "$env:USERNAME@<external-ip>" '<command>'
```text
OpenSSH 9.5p2 (preinstalled on Windows 10 1809+ and Server 2019+) handles modern algorithms out of the box. Same for `scp.exe`.

**The proper long-term fix** is patching `ssh.py:206` to flip the `if platforms.OperatingSystem.IsWindows():` condition so OpenSSH is used even on Windows. The file lives in `C:\Program Files (x86)\` which is a protected path — needs PowerShell as admin to edit. The patch:

```diff

-    if platforms.OperatingSystem.IsWindows():
+    if platforms.OperatingSystem.IsWindows() and not os.environ.get('QALOS_GCP_USE_OPENSSH'):
       suite = Suite.PUTTY
       bin_path = _SdkHelperBin()
     else:
       suite = Suite.OPENSSH
       bin_path = None
```text
If the patch is ever applied, all three `gcp-*.ps1` scripts can switch back to `gcloud compute ssh`/`gcloud compute scp` and drop the native OpenSSH helpers.

### 7.7 Aliyun ECS cannot reach `android.googlesource.com` — use two-hop sync

Aliyun ECS in cn-hangzhou (and likely all cn-* regions) **cannot reach** Google's AOSP infrastructure. Verified 2026-09-10 from an `ecs.g7a.*` Spot instance:

| Destination | Result |
|---|---|
| `gerrit.googlesource.com` | Connect timeout |
| `android.googlesource.com` | Connect timeout |
| `storage.googleapis.com` | 403 Forbidden |
| `github.com` | TLS errors |
| `mirrors.aliyun.com/android.googlesource.com` | HTML page only — **not a real git mirror** (`git ls-remote` returns 404). Per Aliyun's own mirror portal, AOSP is not a first-class supported mirror. |

**The correct pattern:** use a Linux box with open internet (192.168.0.45) as the AOSP sync gateway. See §5.5 for the full SSH setup and two-hop sync workflow.

Do not attempt `repo init`/`repo sync` directly on the Aliyun ECS — it will hang or fail on every AOSP project. Do not try `mirrors.aliyun.com` as a substitute — it is not a real git mirror.

### 7.8 Aliyun OSS internal endpoint is 5–10× faster than public (2026-09-11)

**Rule:** when downloading large data into an Aliyun ECS, **always** use the
`-internal` endpoint (`oss-cn-<region>-internal.aliyuncs.com`) instead of the
public one. The internal endpoint is on Aliyun's private backbone, so:

- **No internet egress charge** for the download.
- **5–10× higher throughput** because it doesn't traverse the public internet.
- **No DPI throttling** — port 443 between Aliyun ECS and OSS internal is unmetered.

Measured 2026-09-11 on cn-hongkong, downloading 35.5 GB across 339 files
from the same OSS bucket:

| Endpoint | Throughput | Wall time |
| --- | --- | --- |
| `oss-cn-hongkong.aliyuncs.com` (public) | ~16 MB/s | ~37 min |
| `oss-cn-hongkong-internal.aliyuncs.com` (internal) | ~110 MB/s | ~5 min |

**Why this matters:** if you're scripting a download, you'll use the public
endpoint everywhere by default. The `-internal` variants exist per region
(oss-cn-hangzhou-internal, oss-cn-shanghai-internal, oss-cn-hongkong-internal,
oss-cn-guangzhou-internal, etc.) and they only work from inside an Aliyun
ECS in the same region. Don't try to use them from outside Aliyun — they're
not publicly resolvable.

**Apply when:** any large-data transfer into an Aliyun ECS (artifacts,
source trees, model checkpoints). For uploads from outside Aliyun, you
have to use the public endpoint (the only one resolvable from the
internet), so the upload speed is limited to whatever your ISP+Aliyun
public routing allows.

### 7.9 ECS sizing for 100+ GB archive extraction (2026-09-11)

**Rule:** for extracting a zstd-compressed tarball of ~35 GB into a
~127 GB directory tree, **don't use ecs.u1-c1m2.large (2 vCPU / 2 GB RAM)**.
The 2 GB RAM is too small — the OS will swap aggressively during
the 127 GB write phase, and the I/O saturation will make SSH
effectively unresponsive (every `du` or `ls -la` times out).

**What to use instead:**

- **For just downloading the source** (no extraction): ecs.u1-c1m2.large
  is fine — the bottleneck is network, not CPU/RAM.
- **For extracting and snapshotting the source**: at least
  ecs.u1-c1m4.large (4 vCPU / 8 GB RAM) — or 4 vCPU / 16 GB to be safe.
  The cat + zstd + tar phases are all single-process and memory-hungry,
  and 2 GB triggers constant swap.
- **For the actual build** (running `m -jN`): at least 64 GB RAM
  (see `tools/aliyun/build-cost.md`). 2 vCPU / 2 GB will not start
  soong bootstrap without OOMing.

**Why the cheap 2 vCPU / 2 GB feels appealing but isn't for this
phase:** at ¥0.15/hour, the difference between 2 vCPU and 4 vCPU is
¥0.10/hour. If the extraction takes 2 hours either way (because
the bottleneck is single-thread zstd), the saving is ¥0.20. The cost
of being stuck on a non-responsive ECS for an extra hour of human
debugging is way more than that.

### 7.10 Three-phase extraction: cat | zstd | tar, not one pipe (2026-09-11)

**Rule:** when extracting a multi-volume zstd-compressed tarball
like `aosp.zst.000` … `aosp.zst.338`, **always** split into three
explicit phases with on-disk intermediates. Don't use a single pipe
like `cat aosp.zst.* | zstd -d | tar -xf -`.

**Why:**

1. **Command-line length**: `cat aosp.zst.000 aosp.zst.001 ... aosp.zst.338`
   on the command line is 339 × ~12 chars = ~4 KB. Most shells handle
   this fine, but `tar -cf -` invoked via subprocess from another shell
   sometimes truncates at the first SIGPIPE. Explicit `cat aosp.zst.* > aosp.tar`
   is unambiguous.
2. **Debuggability**: each phase has a measurable output file. If
   phase 2 fails at 80%, you can resume from phase 2 without
   re-doing phase 1. If you have a single pipe, you restart from zero.
3. **Resource isolation**: phase 1 (cat) is I/O-bound, phase 2 (zstd)
   is CPU-bound (single-threaded, no `-T0`), phase 3 (tar) is I/O+metadata
   bound. A single pipe mixes all three so you can't tell which one is slow.
4. **Failure visibility**: if zstd errors with "invalid frame", you'll
   see it in phase 2's output. In a single pipe, the error appears
   at the tail of a 127 GB tar failure and is much harder to diagnose.

**Concrete recipe (proven 2026-09-11):**

```bash
# Phase 1: concatenate. Reads 339 × 100 MB, writes 1 × 35 GB.
# Wall time on 2 vCPU + ESSD PL1: ~12 min.
echo "=== Phase 1: concatenate ===" && date
cat /aosp/aosp.zst.000 /aosp/aosp.zst.001 ... /aosp/aosp.zst.338 > /aosp/aosp.tar
echo "=== Phase 1 done ===" && date && ls -la /aosp/aosp.tar

# Phase 2: decompress. Reads 35 GB compressed, writes 127 GB raw.
# Single-threaded zstd (zstd -T0 would help but adds RAM pressure on
# 2 GB ECS — measure first). Wall time on 2 vCPU: 30-60 min.
echo "=== Phase 2: zstd decompress ===" && date
zstd -d /aosp/aosp.tar -o /aosp/aosp.tar.raw
echo "=== Phase 2 done ===" && date && ls -la /aosp/aosp.tar.raw

# Phase 3: extract. Reads 127 GB raw, writes ~127 GB of files.
# Wall time on 2 vCPU: 5-10 min.
echo "=== Phase 3: tar extract ===" && date
mkdir -p /aosp-extracted
tar -xf /aosp/aosp.tar.raw -C /aosp-extracted/
echo "=== Phase 3 done ===" && date && du -sh /aosp-extracted/

# Clean up intermediates (saves 162 GB before snapshot).
rm /aosp/aosp.tar /aosp/aosp.tar.raw /aosp/aosp.zst.*
```

**Disk budget for the extraction:** 35 GB compressed + 35 GB
intermediate tar + 127 GB decompressed + 127 GB extracted = 324 GB
peak. A 300 GB disk will run out. Plan for ≥500 GB, or delete the
compressed volumes after phase 1.

## 8. Known limitations / open work

- **Aliyun build scripts removed 2026-09-09.** `tools/aliyun-build.ps1`
  and `scripts/aliyun-build.sh` were deleted via `mavis-trash`
  on 2026-09-09. They had three known bugs (B-1: undefined
  `$ddidx` typo in the wait loop; B-2: `--SecurityGroupId $sgId
  --VSwitchId $vswId` use variables that are never loaded from
  the state file; B-3: the script blocks on `ssh "bash
  /tmp/do-build.sh"` for 1-6 hours, the same shape that bit the
  GCP path on 2026-09-04). The LLM-driven path is the only
  workflow; see [`tools/aliyun/AGENTS.md`](tools/aliyun/AGENTS.md).
  The smoke test and setup-base scripts (which don't have the
  SSH-blocking bug) remain on disk.
- **`do-build.sh` uploads to DO Spaces.** This is wrong for the Aliyun and GCP paths. Both pull artifacts via `scp` (Aliyun incurs ~¥0.4 egress per build for 3 GB; GCP pulls via native `scp.exe` at no egress cost within the region). The clean fix is a `BUILD_UPLOAD_BACKEND=scp|spaces|oss|gcs|none` env var. Now done for the GCP path — `do-build.sh` skips upload when `SPACES_BUCKET` is empty.
- **`default.xml`'s `aosp` remote — FIXED 2026-09-04.** The qalos default.xml used to include `upstream.xml` (a verbatim copy of AOSP's default.xml) which defined `<remote name="aosp" fetch=".."/>`. Under AOSP that resolves to `https://android.googlesource.com/`, but under qalos (`https://github.com/bramburn/qalos.git`) it resolves to `https://github.com/bramburn/`. `repo sync` on a fresh clone of qalos therefore tried to fetch every AOSP project from this fork and failed with "Unable to fully sync the tree / Downloading network changes failed". The fix: removed the duplicate `<remote name="aosp">` from `upstream.xml` and added the canonical definition to `default.xml` with an absolute `fetch="https://android.googlesource.com/"` URL. The `repo` include parser accepts this (the comment that said it rejected duplicates was referring to redefining a remote with different attributes in the same file; the include gets a fresh namespace, so a single canonical definition in the parent manifest is fine).
- **No GH Actions path for Aliyun or GCP.** `.github/workflows/build.yml` is DO-only. Adding parallel `build-aliyun.yml` and `build-gcp.yml` workflows is straightforward but requires GitHub secrets to be set first.
- **GCP SSH workaround is local to the orchestrator scripts.** The right long-term fix is patching `gcloud/.../ssh.py` (see §7.6) so the gcloud CLI uses OpenSSH on Windows. The patch needs admin and is a one-line change. Until then, the `gcp-*.ps1` scripts carry their own `Invoke-Ssh` / `Invoke-ScpUpload` / `Invoke-ScpDownload` helpers using Windows OpenSSH. The [manual agent-driven build guide](website/docs/qa-lab-os/agent-build-shell.md) documents the same primitives for use outside the orchestrator.
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

## 8.2. AOSP dry-run verification workflow

**Any patch that modifies an upstream AOSP file MUST be validated
against the actual upstream source before the patch is considered
ready.** Self-review of the patch as text misses real mismatches
because the author sees what they expect to see.

The full recipe is in
[`website/docs/qa-lab-os/dry-run-workflow.md`](website/docs/qa-lab-os/dry-run-workflow.md)
(human-facing, copy-pasteable PowerShell + bash). The short
version:

1. **Fetch** the real upstream file from
   `https://android.googlesource.com/platform/frameworks/base/+/refs/tags/<AOSP-tag>/<path>?format=TEXT`
   (base64, no newlines).
2. **Decode** with `[Convert]::FromBase64String` (PowerShell) or
   `base64 -d` (bash).
3. **Drop** it into a fake AOSP working tree at the right relative
   path.
4. **Run** the patch script against the tree. If `check-patches.py`
   exits non-zero, the anchor is wrong; fix it.
5. **Diff** the result against the pristine copy. The diff IS
   the patch; if it surprises you, the patch is wrong.

The v0 had three real bugs that two 4-pass reviews missed; the
dry-run caught all three. The full history is in
[`website/docs/qa-lab-os/lessons-learned.md`](website/docs/qa-lab-os/lessons-learned.md).

**Skip this workflow only if the patch is editing a qalos-owned
file** (under `device/qalos/`, `packages/apps/QaLab/`,
`vendor/qalos/`, etc.). The workflow is for patches that modify
files in upstream AOSP repos.

### 8.2.1. Known gap: dry-run validates mechanics, not build behaviour

The dry-run workflow above proves that the **patch applies cleanly**
to the upstream file, but it does **not** prove that the patched
file will **build** under AOSP 15's metalava API-lint checks. This
gap caused a 2h 28m cloud build of v0.1.1 to fail at the 96% mark
on the UnflaggedApi lint for a new `REMOTE_CONTROL` permission
added by patch 0002.

**Root cause:** `tools:ignore="UnflaggedApi"` in the source XML is
stripped by aapt2; metalava lints the **generated** `Manifest.java`,
where the `tools:ignore` never reaches. The proper AOSP 15
suppression is an entry in
`frameworks/base/api/lint-baseline.txt`. Patch 0002 now does both.

**Mandatory pre-flight before launching a cloud build:** every
`do-build.sh` (and its twin scripts) runs a targeted pre-flight
build of just the api-stubs target before the full `m -jN`. This
catches the metalava lint in 5-15 minutes, not 2-4 hours:

```bash

# Inside do-build.sh, immediately after `lunch` and before `m -jN`:
m -jN frameworks/base/api:api-stubs-docs-non-updatable \
    2>&1 | tee "$LOG_DIR/preflight.log" || {
        log "FATAL: preflight metalava check failed"
        log "  See AGENTS.md §8.2.1 for the fix:"
        log "  - frameworks/base/api/lint-baseline.txt for the new symbol, OR"
        log "  - Define an aconfig flag and reference it in the new code."
        shutdown_droplet
    }
```text
**Rule for future patches that touch the framework manifest,
APIs, or services:** after the dry-run succeeds (steps 1-5 above),
the pre-flight MUST be exercised end-to-end at least once on a
throwaway instance. Only after the pre-flight is green is it safe
to launch the full cloud build. This is the only reliable way to
catch the class of bug that costs hours of compute and dollars.

The local-host side of this rule is a "what to check before
launching" checklist (in this file), not a local build invocation
— we cannot install WSL on this machine, and there is no AOSP
toolchain on Windows. The actual pre-flight must run on a real
Linux instance.

## 9. Tactical next steps (for whoever picks this up)

1. **GCP is the cheapest and fastest new-account path right now.** The Aliyun account is blocked at 4 vCPU / 8 GB by risk-control gates.
   ```powershell
   .\tools\gcp-install.ps1                    # verify gcloud is working
   .\tools\gcp-setup-base.ps1                 # one-time: warm snapshot (~10 min)
   .\tools\gcp-build.ps1                      # kick the build
   ```

2. **Aliyun path is LLM-driven, not script-driven** (as of 2026-09-09).
   File a quota increase at
   `https://ecs.console.aliyun.com → 配额管理 → 提交配额申请`
   for the `ecs.g7a` family, 64 vCPU. Approval is typically
   < 1 business day. Then read
   [`tools/aliyun/AGENTS.md`](tools/aliyun/AGENTS.md) and run the
   four phases. The LLM-driven flow does not require the PS1
   scripts.

3. **Enable GitHub Pages** for the Docusaurus site: go to repo **Settings > Pages**, select **GitHub Actions** as the source. The next push to `main` will deploy.
4. **Apply branch protection** with the `gh api` command in `BRANCH_PROTECTION.md`.
5. **Add GH Actions paths** for Aliyun and GCP by copying `.github/workflows/build.yml` and following the pattern.
6. **The artifact-download path is now HTTP, not `scp`.** `do-build.sh`
   writes `/tmp/qalos-artifacts-url.txt`; the systemd unit's
   `ExecStartPost=` starts [`tools/aliyun/qalos-serve-artifacts.py`](tools/aliyun/qalos-serve-artifacts.py);
   the cron and the user download via `curl` or a browser.
   No `BUILD_UPLOAD_BACKEND` refactor needed for the Aliyun
   path; the `SPACES_BUCKET` DO path still uses `s3cmd`.
7. **AOSP source migration to Aliyun uses the HK relay** (proven
   2026-09-11). Don't try to ship 35 GB from the UK to
   `cn-guangzhou` directly — SSH is DPI-throttled to ~1 KB/s
   (§5.4.4) and the public OSS endpoint is blocked at the
   account level (§5.4.2). The working pattern: Mac Mini →
   HK OSS (public endpoint, ~9 MiB/s) → HK ECS via HK OSS
   internal endpoint (~110 MiB/s) → extract 127 GB → snapshot
   → `CopyImage` to cn-guangzhou → launch the build VM from the
   copied image. Full recipe in §5.4.5. Total wall time: ~2.5–3.5
   hours, dominated by zstd decompression on the small HK ECS.

## 10. TL;DR

- **Build locally.** 16 GB+ RAM, 200+ GB disk, Ubuntu 22.04+.
- **Cloud is a fallback.** DO has the battle-tested scripts (`doctl-*.ps1`); Aliyun is the LLM-driven path (read [`tools/aliyun/AGENTS.md`](tools/aliyun/AGENTS.md)) for China-region runs; GCP is the cheapest and fastest new-account path (`gcp-*.ps1`, ~$0.76 for a 6h build, no gates).
- **The on-host build is `do-build.sh`.** All three cloud paths invoke it. Don't fork it.
- **The Aliyun path is LLM-driven** as of 2026-09-09. The agent calls `aliyun ecs ...` via Bash, sets up a `mavis cron` to own teardown, and the build runs as a detached `systemd-run` unit on the instance. See [`tools/aliyun/AGENTS.md`](tools/aliyun/AGENTS.md).
- **AOSP source ships to Aliyun via the HK relay (§5.4.5).** Mac Mini → HK OSS (public) → HK ECS via HK OSS internal endpoint → extract 127 GB → `CreateImage` → `CopyImage` → cn-guangzhou. Direct UK → cn-guangzhou is unusable (~1 KB/s SSH, public OSS endpoint blocked at account level).
- **Four safety nets** prevent orphaned cloud resources. Every new build script MUST implement them.
- **The warm image is the unit of cost optimization.** Pay ~¥8-12/month for the Aliyun image, ~$0.40/month for the DO snapshot, save 30 min per build.
- **GCP: use Spot with a retry mindset.** 30-second preemption notice means a mid-build reclaim costs one extra `m` round — `repo sync` and `ccache` survive it.
- **Aliyun: use `SpotAsPriceGo`** the same way. The build instance is destroyed on any exit; `do-build.sh`'s `MAX_RUNTIME_MINUTES` watchdog is the hard upper bound.
- **Read the gotchas (§7) before you debug Aliyun.** The CLI's error messages are useless; the gotchas are where the real signal is. New in 2026-09-11: §7.8 (OSS internal endpoint speed), §7.9 (ECS sizing for extraction), §7.10 (three-phase extraction).
- **The legal framework in `legal/` is the project's liability shield.** KYC + audit logging are mandatory for any commercial distribution. Contributors accept the CLA by submitting a PR. See §2.9 for the non-negotiables. Every document in `legal/` is currently DRAFT and must be reviewed by a solicitor before reliance.
- **The docs site is at <https://bramburn.github.io/qalos/>** and is the human-facing mirror of this file. Update both when you change architecture.
