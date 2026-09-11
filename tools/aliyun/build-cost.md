# qalos Aliyun build cost

> Cost numbers for the LLM-driven Aliyun build path. Updated
> 2026-09-09. Read alongside
> [AGENTS.md](AGENTS.md) for the high-level flow.
>
> **Correction vs the existing root AGENTS.md §6:** the existing
> doc quotes the Aliyun warm image as ¥1/month. The actual cost
> at ESSD PL1 ¥1/GB/month on an 8-12 GB image is **¥8-12/month**.
> The root doc was updated in this turn.

## Build instance: `ecs.g7a.16xlarge` Spot, 500 GB ESSD PL2

| Property | Value |
|---|---|
| Instance type | `ecs.g7a.16xlarge` |
| vCPU | 64 |
| RAM | 256 GB |
| Processor | AMD EPYC MILAN, 2.55 GHz base / 3.5 GHz turbo |
| Network baseline | 16 Gbit/s |
| AOSP 15 build time (emulator) | 1-1.5 h |
| On-demand price | ~¥12/hr |
| Spot price (`SpotAsPriceGo`, typical) | ~¥3-4/hr |

The 16xlarge is **overprovisioned on RAM** (AOSP sweet spot is 64
GB; 256 GB is fine but the extra sits idle). The user picked it
for **build-time speed** — 64 vCPU halves the build time vs
32 vCPU. The cost is similar to the smaller 8xlarge because the
build is shorter, not because the hourly is similar.

## Per-build cost (spot)

For a typical 1.5-hour build (1 h sync + preflight, 0.5 h full
`m`, plus ~5 min artifact download):

| Component | Calculation | Cost |
|---|---|---|
| Compute (g7a.16xlarge Spot) | ¥3.5/hr × 1.5 h | **¥5.25** |
| System disk (500 GB ESSD PL2) | ¥2.10/hr × 1.5 h | **¥3.15** |
| Egress (scp 3 GB to UK) | ¥0.12/GB × 3 GB | **¥0.36** |
| TUNA mirror (free) | — | **¥0** |
| **Per-build total (spot)** | | **~¥9** |

For a sync + preflight only (~15 min, used to validate the wiring
before the first full build):

| Component | Calculation | Cost |
|---|---|---|
| Compute (g7a.16xlarge Spot) | ¥3.5/hr × 0.25 h | **¥0.88** |
| System disk (500 GB ESSD PL2) | ¥2.10/hr × 0.25 h | **¥0.53** |
| Egress (none — preflight doesn't produce artifacts) | — | **¥0** |
| **Per-build preflight only (spot)** | | **~¥1.4** |

## Per-build cost (on-demand)

For comparison, the same 1.5-hour build on on-demand:

| Component | Calculation | Cost |
|---|---|---|
| Compute (g7a.16xlarge on-demand) | ¥12/hr × 1.5 h | **¥18** |
| System disk (500 GB ESSD PL2) | ¥2.10/hr × 1.5 h | **¥3.15** |
| Egress | ¥0.12/GB × 3 GB | **¥0.36** |
| **Per-build total (on-demand)** | | **~¥21** |

**Spot is ~2.3× cheaper.** The user-picked default is spot
(SpotAsPriceGo).

## Standing cost (no builds running)

| Component | Calculation | Cost |
|---|---|---|
| Warm image (8-12 GB ESSD PL1) | ¥1/GB/month × 10 GB | **¥10/month** |
| OSS bucket (optional, for artifact storage) | — | ¥0 if unused |
| Egress (none when not building) | — | **¥0** |
| **Idle total** | | **~¥10/month** |

If the user wants ¥0 idle cost: delete the warm image between
builds (`aliyun ecs DeleteImage --ImageId m-bp1xxxx`). Re-creating
it takes ~10 min and ~¥0.18 (the base ECS) + ~¥0.20 (the disk).

## Cost-comparison table (all three cloud paths)

For a 1.5-hour AOSP 15 build, plus the warm image standing cost.

| Path | Compute | Disk | Egress | Total per build | Standing |
|---|---|---|---|---|---|
| **Aliyun g7a.16xlarge Spot (qalos default)** | ¥5.25 | ¥3.15 | ¥0.36 | **~¥9** | **~¥10/mo** (warm image) |
| Aliyun g7a.8xlarge Spot (cheaper) | ¥2.55 | ¥3.15 | ¥0.36 | ~¥6 | ~¥10/mo |
| Aliyun on-demand (any) | ¥18 | ¥3.15 | ¥0.36 | ~¥21 | ~¥10/mo |
| GCP c3d-highcpu-16 Spot (16 vCPU / 32 GB) | ~$0.66 | ~$0.30 | free in-region | ~$1.00 | ~$0.03/mo |
| DO c-8 (8 vCPU / 16 GB) | $0.50-0.80 | included | $0 (Spaces) | $0.50-0.80 | $5.40/mo (Spaces + snapshot) |
| Local Linux box | $0 | $0 | $0 | $0 | $0 |

## Spot price volatility

`SpotAsPriceGo` follows the Aliyun market price in real time. The
typical price for `g7a.16xlarge` is stable because the instance
family is heavily used; the user's prior 2026-09-03 probe saw
the g7a family in stock. If the price spikes, Aliyun reclaims the
instance within 5 minutes. The LLM-driven flow's `repo sync` is
resumable and `ccache` survives a reclaim; the on-host watchdog
hard-kills the build at `MAX_RUNTIME_MINUTES=180`; the cron
tears down. A mid-build reclaim adds at most one retry round.

## The "auto-close" rule

The user said on 2026-09-02 (per agent memory):

> Paid cloud compute for builds MUST auto-destroy on
> success/failure/Ctrl+C/hard-kill/timeout. Layer try/finally +
> background watchdog + on-resource watchdog.

The LLM-driven Aliyun flow implements all four safety nets:

1. **`trap` for cleanup** — the LLM's Bash command runs
   `aliyun ecs StopInstance` + `DeleteInstance` on any Bash error.
2. **Background watchdog** — replaced by the `mavis cron` (safety
   net #4). The cron is in a separate session, so it survives an
   agent process death.
3. **On-host bash watchdog** — `do-build.sh`'s
   `MAX_RUNTIME_MINUTES=180` calls `shutdown -h now` at 3 h.
4. **`mavis cron` monitor** — created by the LLM in the same
   turn as the `RunInstances` call; ticks every 10 min; owns
   `DeleteInstance` after artifact download.

The LLM-driven flow is **strictly better** than the PS1 path on
safety net #2: the cron survives an agent process death, where
the PS1's `Start-Job` watchdog would force-delete a healthy
build (the 2026-09-04 GCP incident pattern).

## Cost-scaling tips

If the user later wants to optimize:

- **Drop to `g7a.8xlarge`** (32 vCPU / 64 GB, ~¥1.7/hr spot, ~1.5-2
  h build). Same RAM, half the cores. Per-build cost ~¥6; standing
  cost unchanged.
- **Drop disk to 40 GB ESSD PL1** (the minimum). Per-build cost
  drops by ~¥2.5 (disk is ¥0.17/hr at PL1 vs ¥2.10/hr at PL2).
  Java compile runs ~20 % slower; total build time +15 min on
  64 vCPU.
- **OSS bucket for artifacts** instead of `scp` to the UK. Same
  cost as scp egress (¥0.12/GB), but avoids the public-internet
  hop. Useful if the user ever relocates the orchestrator to a
  China-region machine.
- **Delete the warm image between builds** for ¥0 idle. ~10 min
  to re-create.
