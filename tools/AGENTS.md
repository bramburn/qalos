# qalos/tools — AGENTS.md

> Index for the `tools/` folder. One page. Every script is listed
> with a one-line description. Long-form docs live in subfolders.
> When in doubt, read the subfolder first.

## On-host scripts (run on the Linux build instance)

| Script | What it is | Run by |
|---|---|---|
| `do-build.sh` | **Single source of truth** for the AOSP build. Steps: watchdog → repo init → repo sync → `apply-qalos.sh` → preflight `api-stubs-docs-non-updatable` → full `m` → write `/tmp/qalos-artifacts-url.txt` (the URL the cron uses to download the artifacts over HTTP). Used by every cloud path and (in principle) by local Linux. | All cloud paths. |
| `setup-droplet.sh` | One-time base-image setup: `apt install` of AOSP build deps, `repo` tool, `ccache`, `jq`. Captured into the warm image. | DO and Aliyun warm-image setup. |
| `apply-qalos.sh` | Copies the qalos overlay (device tree, `QaLab`, `RemoteControlService`) into the AOSP working tree and runs the 3 Python "patches" against upstream AOSP files. Idempotent; runs the patch verifier first. | `do-build.sh` step 3. |

## Windows orchestrators (`tools/*.ps1`)

| Script | Provider | Status | When to use |
|---|---|---|---|
| `aliyun-install.ps1` | Aliyun | OK | One-time. Idempotent. Installs the aliyun CLI. |
| `aliyun-smoke-test.ps1` | Aliyun | OK as reference | Optional validate-create-SSH-delete probe. The LLM runbook's Phase 2 is the preferred path; this script is kept for users who prefer scripts. |
| `aliyun-setup-base.ps1` | Aliyun | OK as reference | One-time warm-image creation. Reads `.pi/aliyun-state.json` correctly. |
| `doctl-install.ps1` | DigitalOcean | OK | One-time. |
| `doctl-setup-base.ps1` | DigitalOcean | OK | One-time warm-snapshot creation. |
| `doctl-build.ps1` | DigitalOcean | OK | On-demand build. Battle-tested; the LLM-driven pattern was prototyped on Aliyun first. |
| `doctl-avd.ps1` | DigitalOcean | OK | On-demand AVD for manual QA. |
| `gcp-install.ps1` | GCP | OK | One-time. |
| `gcp-smoke-test.ps1` | GCP | OK | Optional validate-create-SSH-delete probe. |
| `gcp-setup-base.ps1` | GCP | OK | One-time warm-snapshot. |
| `gcp-build.ps1` | GCP | **Use with caution** — has a known SSH-shutdown bug that can delete a healthy build after 4 hours. See root AGENTS.md §5.5 warning. The LLM pattern (`systemd-run` + mavis cron) is the right fix; `qalos-launch.ps1` (sibling at the repo root) is the working example. | Use only for short jobs (< 10 min) or with the LLM cron + systemd-run pattern. |

> **Removed 2026-09-09:** `tools/aliyun-build.ps1` and
> `scripts/aliyun-build.sh` were removed (use `mavis-trash` to
> recover if needed). They had three known bugs (B-1: `$ddidx` typo
> in the wait loop; B-2: missing `$sgId`/`$vswId` load from the
> state file; B-3: blocking on SSH for 1-6 hours, the same shape
> that bit the GCP path on 2026-09-04) and were superseded by the
> LLM-driven runbook at `tools/aliyun/AGENTS.md`. The smoke test
> and setup-base scripts remain because they don't have the
> SSH-blocking bug.

## macOS / Linux twins (`scripts/*.sh`)

| Script | Twin of | Status |
|---|---|---|
| `aliyun-install.sh` | `tools/aliyun-install.ps1` | OK |
| `aliyun-smoke-test.sh` | `tools/aliyun-smoke-test.ps1` | OK as reference. |
| `aliyun-setup-base.sh` | `tools/aliyun-setup-base.ps1` | OK as reference. |
| `lib/aliyun-common.sh` | (n/a) | Shared helper: `aliyon()`, `get_state`, `save_state`. Used by the smoke test and setup-base shells. **Known issue:** `smallest_in_stock_instance_type` uses bare `aliyun` instead of `$QALOS_ALIYUN` — breaks on Windows Git Bash without a `.bat` shim. The LLM-driven runbook does not use this function. |
| `lib/log.sh` | (n/a) | Shared log helpers. OK. |

> **Removed 2026-09-09:** `scripts/aliyun-build.sh` (the macOS/Linux
> twin of the deleted `tools/aliyun-build.ps1`) was removed
> alongside its .ps1 sibling. The `.sh` smoke test and setup-base
> remain.

## Per-provider LLM runbooks

| Provider | Runbook | Notes |
|---|---|---|
| Aliyun | **[`tools/aliyun/AGENTS.md`](aliyun/AGENTS.md)** | The LLM-driven runbook. Self-contained and execution-ready. The LLM reads this and calls `aliyun ecs ...` via Bash directly. Includes Phase 4's HTTP artifact-download path. |
| Aliyun CLI | [`tools/aliyun/aliyun-cli-reference.md`](aliyun/aliyun-cli-reference.md) | Cheat sheet for every `aliyun ecs ...` command the runbook uses. |
| Aliyun cost | [`tools/aliyun/build-cost.md`](aliyun/build-cost.md) | The cost table — per-build + standing + scaling. |
| Aliyun artifact server | [`tools/aliyun/qalos-serve-artifacts.py`](aliyun/qalos-serve-artifacts.py) | The token-gated Python HTTP server that serves the build artifacts over a one-shot URL. |
| GCP | (no runbook yet; see `qalos-launch.ps1` at the repo root for the working example, and `website/docs/qa-lab-os/agent-build-shell.md` for primitives) | The `gcp-*.ps1` scripts are usable for short jobs; the LLM pattern (`systemd-run` + mavis cron) is the right long-build path. |
| DigitalOcean | (covered by the existing `doctl-*.ps1` scripts) | Battle-tested; the LLM pattern can layer on top but is not yet a runbook. |

## Four safety nets (every cloud build must implement all four)

Per the root `AGENTS.md` §2.3. The LLM-driven path implements them
as follows:

1. **`trap` for cleanup** in the agent's Bash command — run
   `aliyun ecs StopInstance` + `DeleteInstance` on early failure.
2. **Background watchdog** — N/A in the LLM-driven path; the
   `mavis cron` (safety net #4) covers this.
3. **On-host bash watchdog** — `do-build.sh`'s `MAX_RUNTIME_MINUTES`
   calls `shutdown -h now` after 180 min (3 h).
4. **`mavis cron` monitor** — created by the LLM in the same turn
   as the `RunInstances` call; ticks every 10 min; owns
   `aliyun ecs DeleteInstance` after artifact download.

The LLM-driven path is strictly better than the PS1 path on safety
net #2: the cron survives an agent process death, where the PS1's
`Start-Job` watchdog would force-delete a healthy build.

## How to extend this runbook for a new build

The Aliyun LLM runbook is the template for any new cloud build
target — a new instance type, a new region, a new provider, or a
new qalos product variant. To add a new build target, follow this
shape:

1. **Decide the layer.** Three layers:
   - **On-host** (`tools/*.sh`): the code that runs on the Linux
     build instance. The AOSP build itself (`do-build.sh`) is the
     single source of truth; for a new AOSP target, override
     `BUILD_TARGET` / `BUILD_VARIANT` env vars. For a non-AOSP
     target, write a new `do-<target>-build.sh`.
   - **LLM runbook** (`tools/<provider>/AGENTS.md`): the per-provider
     runbook the LLM reads to drive the build. Mirror the
     `tools/aliyun/AGENTS.md` structure (Prerequisites, State,
     Phase 2 smoke, Phase 3 warm image, Phase 4 build, Phase 5
     first real build, failure modes, AOSP API check, deprecation).
   - **CI / docs** (`.github/workflows/`, `website/docs/`): human-
     facing mirror and CI triggers. Update alongside the runbook
     per the "always update both" rule in the root AGENTS.md.
2. **Implement the four safety nets** (see the table above). Every
   cloud build MUST have all four; this is non-negotiable.
3. **Use the warm-image pattern** (root AGENTS.md §2.2). The first
   build always pays for the apt-install; every subsequent build
   launches from the warm image. For a new provider, the warm-image
   primitive is different (Aliyun custom image, DO snapshot, GCP
   persistent disk snapshot), but the shape is the same.
4. **Use spot for the build instance** (root AGENTS.md §2.4). Build
   compute is interruptible; warm-image storage is not.
5. **Use the LLM-monitor-cron pattern** (root AGENTS.md §2.8). The
   agent sets up a `mavis cron` that owns the instance lifetime;
   the build script (if any) returns in ~2 min. Do NOT block the
   agent's Bash call on a 1-6 hour build.
6. **Serve the artifacts over HTTP** (see the
   `tools/aliyun/qalos-serve-artifacts.py` pattern). After the
   build finishes, start a token-gated HTTP server on the
   instance; the cron or the user downloads via `curl` or a
   browser. This avoids the SSH-key-on-orchestrator requirement
   of `scp`.
7. **Update this `AGENTS.md` index** and the per-provider runbook
   with the new path.
8. **Update the cost table** in `build-cost.md` for the new
   instance type / region.
9. **Run the local CI checks** (PSScriptAnalyzer, shellcheck,
   markdownlint, gitleaks, lychee) before pushing.

For a new provider (e.g., Hetzner, Azure), copy the entire
`tools/aliyun/` subfolder to `tools/<provider>/`, rewrite the
CLI commands in the runbook, mirror the cheat-sheet and cost
table, and add the per-provider entry to the runbook table
above. The smoke test (Phase 2) and warm image (Phase 3) need
provider-specific implementations; the build phase (Phase 4)
is largely provider-agnostic if `do-build.sh` does the actual
work.

## Deprecation policy

- Scripts in this folder are removed (via `mavis-trash`) when the
  LLM-driven path is the only one. Removal is preferred over
  "DEPRECATED but kept" because the LLM has a strong tendency to
  follow stale code on disk. The smoke test and setup-base
  scripts are the exception: they remain because they have a
  different control flow and no SSH-blocking bug.
- The CI's `lint-powershell` and `lint-shell` checks (root
  AGENTS.md §3) scan the folder globs; removing files does not
  break the CI.
- The B-1/B-2/B-3 bugs that lived in `aliyun-build.ps1` are
  documented here for posterity; if the file is recovered from
  trash, fix the bugs before any first-run use.

## When you need to add a new script

1. Decide which layer: on-host (Linux; goes in `tools/*.sh`),
   LLM runbook (`tools/<provider>/AGENTS.md`), or shared library
   (`scripts/lib/*.sh`).
2. If it's an on-host script that runs on the build instance, it
   must implement the four safety nets.
3. If it's an LLM runbook for a new provider, mirror the
   `tools/aliyun/AGENTS.md` structure.
4. Update this `AGENTS.md` index and the relevant subfolder
   `AGENTS.md`.
5. Run the local CI checks (shellcheck for `.sh`, ruff/pylint for
   `.py`, PSScriptAnalyzer for `.ps1`, markdownlint for `.md`)
   before pushing.
