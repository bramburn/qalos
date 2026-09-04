---
sidebar_position: 5
---

# GCP build (fallback #3)

The GCP path is the cheapest and fastest **new-account** cloud build path. No risk-control gates, $0 idle cost, ~$0.76 for a 6-hour Spot build on `c3d-highcpu-16`. The scripts mirror the DO and Aliyun orchestrators, with GCP Compute Engine primitives (instances, persistent disk snapshots, Spot, default-allow-ssh firewall).

## Prerequisites

- A Google Cloud account with a project that has billing enabled.
- The `gcloud` CLI installed and authenticated (`gcloud auth login`).
- A Windows / macOS / Linux machine to run the orchestrator from.
- **Windows host note:** see [SSH transport](#ssh-transport-windows-only) below. On Windows, the scripts call native OpenSSH directly, not `gcloud compute ssh`, because the gcloud SDK hardcodes PuTTY/Plink which fails against modern Linux VMs.

## Is `c3d-highcpu-16` enough?

**Yes** for `qalos_emulator-userdebug`. That's 16 vCPU / 32 GB RAM, which clears the AOSP build's -j16 bound. A first build takes 5-6 hours; subsequent builds reusing the warm snapshot's `ccache` complete in 1-2 hours.

If the Java compile OOMs (rare; check `/root/aosp/.qalos-logs/build.log` for `OutOfMemoryError: Java heap space`), step up to `c3d-standard-16` (16 vCPU / 64 GB) — the build will be marginally slower because the highcpu class has faster single-core clock, but it won't OOM.

For Android 17+ (future), make `c3d-standard-16` the default.

## Cost

| Component | Standing | Per 6h build |
|---|---|---|
| `qalos-build-warm` pd-ssd snapshot (~1 GB incremental) | ~$0.03/month | — |
| `c3d-highcpu-16` Spot us-central1 | $0 | ~$0.76 |
| `c3d-standard-16` Spot us-central1 | $0 | ~$0.92 |
| Egress (artifacts back to your machine) | — | free within the same region |

Spot can be reclaimed with 30-second notice. `repo sync` is resumable and `ccache` survives a reclaim, so a mid-build preemption adds one extra `m` round at worst. Use Spot with a retry mindset.

## One-time setup (~15 min)

```powershell
# 1. Install / verify the gcloud CLI
.\tools\gcp-install.ps1

# 2. (Optional) smoke test: validate create + SSH + delete end-to-end
.\tools\gcp-smoke-test.ps1
#    Cost: ~$0.004, runs in ~1 minute. Use this to debug SSH / auth issues.

# 3. Create the warm snapshot (apt-install AOSP build deps once)
.\tools\gcp-setup-base.ps1
#    Cost: ~$0.05 for ~5 min of e2-medium. Output: a 8-15 GB pd-ssd snapshot
#    called 'qalos-build-warm' in your project.
```

The setup script:
1. Launches an `e2-medium` base instance from `debian-12` in `us-central1-a`.
2. Runs `tools/setup-droplet.sh` to install every AOSP build dependency.
3. Stops the base instance.
4. Creates a `qalos-build-warm` persistent disk snapshot from the boot disk.
5. Deletes the base instance. Snapshot lives on at ~$0.03/month (GCP persistent-disk snapshots are incremental — even a 200 GB source disk snapshots to ~1 GB of actual data, not the full disk size).
6. Writes `.pi/gcp-state.json` with snapshot name, project, zone.

## On-demand build

```powershell
# Standard: 16 vCPU / 32 GB, ~$0.76 for 6h
.\tools\gcp-build.ps1

# 64 GB RAM if c3d-highcpu-16 OOMs
.\tools\gcp-build.ps1 -InstanceType c3d-standard-16

# Tighter cap on the on-host watchdog (default 240 min)
.\tools\gcp-build.ps1 -MaxRuntimeMinutes 360

# Debug: leave instance up 30 min on failure so you can ssh in
.\tools\gcp-build.ps1 -KeepOnFailure
```

What the build script does:
1. Creates a Spot instance from the `qalos-build-warm` snapshot. Provisions `MAX_RUNTIME_MINUTES` minutes of Spot uptime.
2. Waits for the instance to be RUNNING.
3. **Uploads `do-build.sh` and a generated env file** to the instance via native `scp.exe` (see SSH transport below).
4. Runs `do-build.sh` over SSH — same script DO and Aliyun use, single source of truth.
5. Polls the build log via `tail -f` (you can also watch by hand: `ssh -i $env:USERPROFILE\.ssh\google_compute_engine "$env:USERNAME@<ext-ip>" 'tail -f \$HOME/aosp/.qalos-logs/build.log'`).
6. Downloads the build artefacts (`system.img`, `boot.img`, `userdata.img`, `vendor.img`, `product.img`, `build.log`) to `.pi/out/gcp-build/<timestamp>/`.
7. Stops and deletes the instance. **Always.** Even on Ctrl+C, hard kill, or the orchestrator crashing.

> **⚠️ Do NOT let `gcp-build.ps1` own the build for > 10 min — the SSH-shutdown gotcha**
>
> `gcp-build.ps1`'s step 4-7 has a known shutdown-detection bug: when the remote `do-build.sh` process tree exits, the parent SSH session does not always close promptly. The script then sits "waiting" for **up to 4 hours**, until the SSH connection eventually drops for some other reason. At that point the script's `try/finally` block runs and **unconditionally stops and deletes the instance** — even if the build itself is healthy and is running via a separate `systemd-run` unit on the same instance.
>
> **Real incident (2026-09-04):** `qalos-build-20260904-180634` was at 45% (`BUILD_RUNNING`, compiling libLLVM AArch64) for 4 hours, then the gcp-build.ps1 background task finally exited and deleted the instance. All 4 hours of compile progress were lost.
>
> **The correct pattern for an AOSP build on GCP (1-6 hours):**
>
> 1. `gcp-build.ps1` may create the instance and upload files, but should NOT own the cleanup. (You can manually delete the instance after the build is done, or use `-KeepOnFailure` to leave it up for inspection.)
> 2. **Launch the build itself via `systemd-run`** on the instance, so it survives any SSH-disconnect that gcp-build.ps1 might suffer. Pattern:
>    ```bash
>    systemd-run --unit=qalos-build --setenv=HOME=/root --setenv=XDG_CACHE_HOME=/root/.cache /tmp/do-build.sh
>    ```
> 3. **The LLM monitor cron is the single owner of `gcloud compute instances delete`** (see [Safety nets → LLM-driven cron](../architecture/safety-nets.md#build-monitor-cron-llm-driven-not-script-driven)). The cron's step 6 runs after artifact download.
> 4. The proper long-term fix is patching `gcp-build.ps1` to remove the unconditional `try/finally` delete, or to add a `-NoAutoDelete` switch.
>
> **TL;DR:** for any build longer than ~10 min, treat `gcp-build.ps1` as a "create + upload" tool only. Launch the actual build via `systemd-run` on the instance, and let the LLM monitor cron own the instance teardown.

## Safety nets (the four layers)

The script implements all four safety nets to guarantee the instance is never orphaned:

1. **`try/finally`** — the main cleanup runs on graceful exit, Ctrl+C, or PowerShell errors.
2. **On-host watchdog** in `do-build.sh` — `shutdown -h now` after `MAX_RUNTIME_MINUTES` elapses. Catches orchestrator-unreachable.
3. **Background PowerShell job** started at instance creation — polls for the parent process; if it dies, calls `gcloud compute instances stop` then `delete`. Catches hard-kill, network partition, parent PowerShell crash.
4. **Final describe check** in `finally{}` — if `describe` returns anything other than `NOT_FOUND` after Stop+Delete, retries once and warns loudly if still alive.

The worst possible failure mode is leaving a Spot instance running overnight. With a max-runtime cap of 240 min, even a fully orphaned instance bills out at most $0.50–0.60. The 4 safety nets are why that doesn't happen.

**Caveat:** Layer 1's unconditional delete is exactly the gotcha described in the warning above. Treat the script as a create/upload tool for long builds.

## SSH transport (Windows only)

On Windows hosts, the `gcp-*.ps1` scripts do **not** use `gcloud compute ssh` or `gcloud compute scp`. Those commands use PuTTY/Plink, which has two failure modes against modern Linux VMs:

1. Plink's TLS handshake to the IAP proxy (`tunnel.googleapis.com:443`) is rejected on some Windows hosts.
2. Plink's SHA-1 RSA signature is rejected by Debian 12 / OpenSSH 8.8+ servers (`PubkeyAcceptedAlgorithms` excludes the legacy `ssh-rsa`).

Instead, the scripts call `C:\Windows\System32\OpenSSH\ssh.exe` and `scp.exe` directly. OpenSSH 9.5p2 (preinstalled on Windows 10 1809+ and Server 2019+) handles modern algorithms out of the box. The scripts use:

- Key file: `%USERPROFILE%\.ssh\google_compute_engine` (generated on first `gcloud compute ssh` invocation).
- Username: `$env:USERNAME` — the GCP guest agent auto-creates this user on the instance and drops the public key into its `~/.ssh/authorized_keys`.
- Instance IP: external NAT, fetched via `gcloud compute instances describe ... --format='value(networkInterfaces[0].accessConfigs[0].natIP)'`. The default `default-allow-ssh` firewall rule already accepts port 22 from the internet, so no IAP tunneling is needed.

For details, see [GCP gotchas: §7.6 gcloud compute ssh uses PuTTY/Plink on Windows](../reference/gotchas.md#gcp-gcloud-compute-ssh-uses-puttyplink-on-windows-and-fails-against-modern-linux).

## Picking a region

`us-central1-a` is the default. It's the cheapest region for Spot on the `c3` family. Other US regions (`us-east1`, `us-west1`) are within 5% on price. Don't pick a region that doesn't have `c3d` instance types — `gcloud compute instances create` will fail with `Invalid zone`.

```powershell
# List zones that have c3d
gcloud compute zones list --filter="name=us-central1-*" --format="value(name)"
```

## Troubleshooting

**"Permission denied (publickey)"** on first SSH attempt:
The key has been added to project metadata but the instance is brand new and the guest agent hasn't picked it up yet. Wait 30 seconds and retry. The smoke test handles this with a 30-attempt loop (2.5 minutes total).

**"Connection refused"** on port 22:
The instance is still booting. `sshd` on Debian 12 starts ~30 seconds after RUNNING. Wait.

**Build OOMs with `OutOfMemoryError: Java heap space`**:
Switch to `c3d-standard-16` (64 GB). Don't try to add swap; AOSP's build system doesn't respect swap.

**Spot preemption mid-build**:
The 30-second preemption notice is logged by the instance. The on-host watchdog will see it and shut down cleanly. `repo sync` resumes on the next run; `ccache` is on the persistent disk so the next build from the warm snapshot keeps the cache.

**`gcp-build.ps1` deleted the instance while the build was still running (the SSH-shutdown bug)**:
The build itself was running via a separate `systemd-run` unit, so the in-progress build was killed too. There is no way to recover — `out/` is gone with the instance. Fix: re-run the build using the `systemd-run` pattern documented in the warning box above, and let the LLM monitor cron own the cleanup.

**Orphaned instance** (should never happen with safety nets, but):
```powershell
gcloud compute instances list --zones=us-central1-a --format="value(name,status)"
# If a qalos-* instance is RUNNING:
gcloud compute instances delete <name> --zone=us-central1-a --quiet
```
