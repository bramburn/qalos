# qalos — QA Lab Operating System

qalos is an Android-based operating system (a fork of AOSP) for QA Lab use, with **Samsung Galaxy A16 5G** as the long-term target device and the **Android emulator (AVD)** as the day-to-day build/test target.

The fork is bare-bones: same kernel, same HALs as upstream AOSP, with a custom product makefile that overrides the OS branding (`QA Lab Operating System`, build id `QAL.YYYYMMDD.001`) and ships one first-party app (`QaLab`).

## Why this exists

We can't build AOSP locally on the Windows workstation — WSL2 isn't installable here. The qalos build runs on **throwaway DigitalOcean droplets** spun up from a pre-warmed snapshot, and the droplets are destroyed the moment the build finishes.

The build host is a **c-8: 8 vCPU / 16 GB RAM / 200 GB SSD** at `$0.176/hr`. One full AOSP build (first sync + first `m`) takes 2–4 hours and costs **~$0.50–$0.80**. Standing cost is essentially zero: a $0.40/month `qalos-build-warm` snapshot + a $5/month Spaces bucket for artifacts.

## Build triggers

| Trigger | When | How |
| --- | --- | --- |
| **GH Actions** | push to `main` / weekly Sunday 03:00 UTC / manual "Run workflow" | `.github/workflows/build.yml` |
| **`doctl-build.ps1`** | from this Windows box, on demand | `.\tools\doctl-build.ps1` |
| **`doctl-avd.ps1`** | from this Windows box, for live AVD testing over SSH-tunneled ADB | `.\tools\doctl-avd.ps1` |

The three auto-close the droplet on **success, failure, Ctrl+C, hard kill of the parent process, and at the max-runtime hard cap**. There are four redundant safety nets so a droplet can never be left running and burning money:

1. `try { ... } finally { doctl ... delete }` in the PowerShell scripts (clean exit).
2. A background PowerShell `Start-Job` watchdog that force-destroys the droplet if the parent process dies (catches `kill -9`).
3. An on-droplet bash watchdog that `shutdown -h now`s the droplet at `MAX_RUNTIME_MINUTES` (catches the case where neither the GH Actions nor the PowerShell orchestrator is reachable).
4. GH Actions `if: always()` cleanup step with `timeout-minutes: 360`.

## Repo layout

```
.
├── default.xml                            # the AOSP manifest; pins android-15.0.0_r1
├── device/qalos/qalos_emulator/           # qalos product makefile (branding, build id)
├── packages/apps/QaLab/                   # the only first-party qalos app
├── tools/
│   ├── setup-droplet.sh                   # one-time base-droplet setup (AOSP build deps)
│   ├── do-build.sh                        # on-demand build (runs on a fresh droplet)
│   ├── doctl-install.ps1                  # install doctl on this Windows box
│   ├── doctl-setup-base.ps1               # one-time: create base droplet + snapshot
│   ├── doctl-build.ps1                    # on-demand build trigger
│   └── doctl-avd.ps1                      # on-demand AVD trigger
├── .github/workflows/build.yml            # GH Actions workflow
├── docs/setup.md                          # first-time setup walkthrough
└── README.md                              # you are here
```

## First-time setup

See [`docs/setup.md`](docs/setup.md). TL;DR: create a DO account, generate a token, create a Spaces bucket + keys, register an SSH key, push this repo to GitHub, set GH secrets, run `tools/doctl-install.ps1` and `tools/doctl-setup-base.ps1`.

## Building

From this Windows box:

```powershell
# Normal CI-style build (droplet created, built, uploaded, destroyed)
.\tools\doctl-build.ps1

# Upgrade to 32 GB RAM if c-8 hits OOM
.\tools\doctl-build.ps1 -DropletSize c-16

# Keep the droplet alive for 30 min on failure so you can SSH in and inspect logs
.\tools\doctl-build.ps1 -KeepOnFailure

# Interactive AVD (droplet stays alive, ADB tunneled over SSH)
.\tools\doctl-avd.ps1
```

Or from GitHub: push to `main`, or click **Run workflow** in the Actions tab.

## Device support

| Target | Status |
| --- | --- |
| x86_64 emulator (AVD) | **First target.** `lunch qalos_emulator-userdebug` builds a working AVD. |
| Samsung Galaxy A16 5G (Exynos 1330, SM-A166B) | **Future.** Needs Samsung's kernel + HAL from `opensource.samsung.com` and a custom device tree. Multi-month port; the upstream community (`LineageOS`, `crDroid`, `PixelExperience`) usually has a head start worth tracking. |

## Cost

| Resource | Standing | Per build |
| --- | --- | --- |
| `qalos-build-warm` snapshot (~3 GB) | $0.40/month | — |
| DO Spaces (artifacts, 250 GB) | $5/month | — |
| Build droplet (c-8) | $0 | $0.50–$0.80 (1.5–4 hours) |
| AVD droplet (c-8, kept alive) | — | $0.18/hour while up |
| Weekly Sunday smoke build (GH Actions) | $0 (within free minutes) | $0 |

Build 4× a week and you spend **~$10/month standing + ~$3 in build hours**. Idle, the project costs **~$5.40/month** in storage.
