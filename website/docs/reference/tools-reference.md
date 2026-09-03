---
sidebar_position: 3
---

# Tools reference

Every script in `tools/` and `scripts/`, with what it does, what it takes, and the safety nets it implements.

## On-host scripts (run on the build instance)

### `tools/do-build.sh` — the single source of truth

The **only** on-host build script. Both the DO and Aliyun orchestrators invoke it. If the AOSP build steps ever change, they change in this file.

- **Runs on:** the build instance (Linux).
- **Invoked by:** the orchestrator over SSH, after scp-ing the file onto the instance.
- **Inputs:** env vars (`BUILD_TARGET`, `BUILD_VARIANT`, `MAX_RUNTIME_MINUTES`, `AOSP_TAG`, `QALOS_REPO_URL`, plus Spaces creds for artifact upload).
- **Outputs:** `*.img` files in `~/aosp/out/target/product/<target>/`, uploaded to DO Spaces.

### `tools/setup-droplet.sh` — one-time base setup

Runs on the **base** instance during `*-setup-base` to install every AOSP build dependency. Result is captured in the warm snapshot/image.

- **Runs on:** the base instance (Linux).
- **Invoked by:** `doctl-setup-base.ps1` or `aliyun-setup-base.ps1` over SSH.
- **What it does:** `apt install` of ~50 packages (gcc, g++, java, repo, ccache, flex, bison, ...). Configures ccache. Installs the Android SDK platform tools.

### `tools/apply-qalos.sh` — overlay qalos content

Copies the qalos product files (from the manifest repo) into the AOSP working tree. Idempotent.

- **Runs on:** the build instance, after `repo sync`.
- **What it copies:** `device/qalos/`, `packages/apps/QaLab/`, and the qalos-specific manifest bits.

## Windows orchestrators (PowerShell, `tools/*.ps1`)

### `doctl-install.ps1` — install doctl on this Windows box

One-time setup. Idempotent (detects an existing install). Adds `doctl` to user PATH.

```powershell
.\tools\doctl-install.ps1
```

### `doctl-setup-base.ps1` — create DO base droplet + warm snapshot

One-time. Spins up a fresh c-8, runs `setup-droplet.sh`, snapshots as `qalos-build-warm`, deletes the base. ~10 min.

**Safety nets:** try/finally.

```powershell
.\tools\doctl-setup-base.ps1
.\tools\doctl-setup-base.ps1 -DropletSize c-16 -Region lon1
```

### `doctl-build.ps1` — on-demand DO build

Launches a droplet from `qalos-build-warm`, scp's `do-build.sh` onto it, runs the build, uploads artifacts to Spaces, destroys. ~2-4 h.

**Safety nets:** try/finally + Start-Job watchdog + on-droplet bash watchdog + GH Actions `if: always()` (the only script with all four).

```powershell
.\tools\doctl-build.ps1
.\tools\doctl-build.ps1 -DropletSize c-16 -BuildVariant eng -MaxRuntimeMinutes 360
```

### `doctl-avd.ps1` — on-demand DO AVD

Launches an AVD on a droplet for manual QA. See the script's comment header for the AVD setup.

### `aliyun-install.ps1` — install aliyun CLI on this Windows box

One-time setup. Idempotent. Adds `aliyun` to user PATH at `%LOCALAPPDATA%\AliyunCLI\`.

```powershell
.\tools\aliyun-install.ps1
```

### `aliyun-smoke-test.ps1` — Aliyun smoke test + bootstrap

The Aliyun path needs VPC, vSwitch, Security Group, and KeyPair before any build can launch. This script:

1. Creates (or reuses) all four of those.
2. Launches the smallest in-stock ECS in `cn-hangzhou / cn-hangzhou-h`.
3. Confirms it reaches `Running`.
4. Stops and deletes the instance.
5. Writes the IDs to `.pi/aliyun-state.json`.

Cost: under ¥0.05. ~3 min.

**Safety nets:** try/finally + Start-Job watchdog. (No on-host watchdog — the instance is only alive for ~60 s.)

```powershell
.\tools\aliyun-smoke-test.ps1
```

### `aliyun-setup-base.ps1` — create Aliyun base ECS + warm custom image

One-time. Same pattern as `doctl-setup-base.ps1` but for Aliyun. ~15 min.

**Safety nets:** try/finally + Start-Job watchdog.

```powershell
.\tools\aliyun-setup-base.ps1 -InstanceType ecs.u1-c1m8.2xlarge
```

### `aliyun-build.ps1` — on-demand Aliyun build

Launches an ECS from `qalos-build-warm`, scp's `do-build.sh` onto it, runs the build, scp's artifacts off, destroys. ~2-6 h.

**Safety nets:** try/finally + Start-Job watchdog + on-host bash watchdog. (No GH Actions path yet.)

```powershell
.\tools\aliyun-build.ps1
.\tools\aliyun-build.ps1 -InstanceType ecs.u1-c1m8.2xlarge -BuildVariant eng -MaxRuntimeMinutes 360
```

## macOS / Linux orchestrators (shell, `scripts/*.sh`)

These mirror the Windows orchestrators. They are not auto-generated — the logic is the same, the syntax differs. The shell scripts use `bash` and call `aliyun` (the Aliyun CLI) directly.

### `scripts/aliyun-install.sh`

```bash
./scripts/aliyun-install.sh
```

Installs the Aliyun CLI to `~/.local/bin/aliyun` (or `/usr/local/bin/aliyun` if run with sudo). Adds to user PATH.

### `scripts/aliyun-smoke-test.sh`

```bash
./scripts/aliyun-smoke-test.sh
```

Same logic as `aliyun-smoke-test.ps1` but in shell.

### `scripts/aliyun-setup-base.sh`

```bash
./scripts/aliyun-setup-base.sh --instance-type ecs.u1-c1m8.2xlarge
```

### `scripts/aliyun-build.sh`

```bash
./scripts/aliyun-build.sh --instance-type ecs.u1-c1m8.2xlarge --max-runtime-minutes 360
```

## Shared library: `scripts/lib/`

| File | Purpose |
| --- | --- |
| `aliyun-common.sh` | `aliyon()` — run aliyun, parse JSON, retry transient errors. `get_state()` / `save_state()` — read/write `.pi/aliyun-state.json`. |
| `log.sh` | `log_info`, `log_warn`, `log_error` with color codes. |

## When you need to add a new script

1. **Decide which layer it belongs to:** on-host (runs on the build instance), orchestrator (runs on your local machine), or shared library.
2. **Implement the four safety nets** if it's an orchestrator that launches a cloud instance. See [Safety nets](../architecture/safety-nets).
3. **Add the .ps1 AND .sh versions** if it's an orchestrator. The two are deliberate twins — same logic, different syntax. Keep them in sync.
4. **Update AGENTS.md and this reference** in the same PR.
5. **Run the local CI checks** (PSScriptAnalyzer, shellcheck) before pushing.

## What's next

- Hit an Aliyun `SDK.ServerError`? → [Gotchas](gotchas)
- Want the design rules these scripts follow? → [Architecture overview](../architecture/overview)
