---
sidebar_position: 3
---

# Safety nets

Every on-demand build script must guarantee the build instance is destroyed, even on parent process death, hard kill, network loss, or uncaught exception. The DO path has four redundant safety nets; the Aliyun path mirrors three of them.

**The worst possible failure mode** for this repo is leaving a ¥15/hour build instance running overnight. The safety nets are why that doesn't happen.

## The four layers

### 1. `try/finally` in the orchestrator script

The `DeleteInstance` call lives in the `finally{}` block. Normal exit, exception, Ctrl+C — it always runs.

This is the **primary** layer. The other three are defense in depth.

```powershell
# PowerShell pattern
try {
    # ... launch, wait, run build ...
}
finally {
    # ALWAYS destroy the instance
    & $aliyun ecs StopInstance --RegionId $Region --InstanceId $instanceId 2>&1 | Out-Null
    Start-Sleep -Seconds 8
    & $aliyun ecs DeleteInstance --RegionId $Region --InstanceId $instanceId --Force true 2>&1 | Out-Null
}
```

```bash
# Shell pattern
trap 'cleanup' EXIT INT TERM
cleanup() {
    [ -n "$INSTANCE_ID" ] && aliyun ecs DeleteInstance --Force true --InstanceId "$INSTANCE_ID" || true
}
```

### 2. Background `Start-Job` / `nohup` watchdog

A PowerShell job (or a nohup'd shell process) runs in a separate process and force-deletes the instance if the parent PowerShell process dies (OOM, `kill -9`, console close).

```powershell
$watchdog = Start-Job -ScriptBlock {
    param($aliyunPath, $region, $instanceId, $parentPid)
    while ($true) {
        Start-Sleep -Seconds 5
        $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
        if (-not $parent) {
            & $aliyunPath ecs StopInstance  --RegionId $region --InstanceId $instanceId 2>$null | Out-Null
            Start-Sleep -Seconds 5
            & $aliyunPath ecs DeleteInstance --RegionId $region --InstanceId $instanceId --Force true 2>$null | Out-Null
            exit 0
        }
    }
} -ArgumentList @($aliyun, $Region, $instanceId, $PID)
```

```bash
# Shell pattern: a nohup'd process that watches the parent PID
( while kill -0 "$PPID" 2>/dev/null; do sleep 5; done
  aliyun ecs DeleteInstance --Force true --InstanceId "$INSTANCE_ID" ) &
```

### 3. On-host bash watchdog

A `nohup`'d shell script on the instance that calls `shutdown -h now` after `MAX_RUNTIME_MINUTES`. Catches the case where the orchestrator loses contact but the instance is still billing.

```bash
# scp'd to the instance and run as: nohup /tmp/onhost-watchdog.sh &
#!/bin/bash
MAX_MIN=240
START_TS=$(date +%s)
while true; do
  NOW_TS=$(date +%s)
  ELAPSED_MIN=$(( (NOW_TS - START_TS) / 60 ))
  if [ "$ELAPSED_MIN" -ge "$MAX_MIN" ]; then
    echo "[on-host watchdog] $MAX_MIN min reached. Forcing shutdown." >&2
    shutdown -h now
    exit 0
  fi
  sleep 60
done
```

### 4. GH Actions `if: always()` cleanup step (DO path only)

Catches GH Actions runner timeouts, runner crash, network partition between runner and DO. The Aliyun script doesn't have this because there's no GH Actions path for it yet. If you add one, copy the pattern from `.github/workflows/build.yml`.

```yaml
- name: Always destroy the droplet
  if: always()
  run: |
    if [ -f droplet_id.txt ]; then
      DROPLET_ID=$(cat droplet_id.txt)
      echo "destroying droplet $DROPLET_ID..."
      doctl compute droplet delete "$DROPLET_ID" --force || true
    fi
```

## Which layer catches which failure?

| Failure | Caught by |
| --- | --- |
| Normal exit (build succeeded) | Layer 1 (`finally`) |
| Build failed (non-zero exit) | Layer 1 (`finally` runs even on exception) |
| `Ctrl+C` from the user | Layer 1 (PowerShell `finally` runs on Ctrl+C) |
| Uncaught exception in the script | Layer 1 (PowerShell `finally` runs on exception) |
| `kill -9 <powershell-pid>` | Layer 2 (Start-Job detects parent gone) |
| OOM kill of the PowerShell process | Layer 2 (same as `kill -9`) |
| Console closed (CI runner crash) | Layer 2 (same as `kill -9`) |
| Network partition: orchestrator alive, instance unreachable | Layer 3 (on-host watchdog self-destructs at MAX_RUNTIME_MINUTES) |
| GH Actions runner timeout | Layer 4 (`if: always()` runs even on timeout) |
| GH Actions runner crash | Layer 4 (same) |

**Every row in this table must be defended against.** A PR that adds a new build script without all four layers will be rejected.

## Build monitor cron — LLM-driven, not script-driven

AOSP builds take 1-6 hours. The orchestrator script (`.ps1` / `.sh`) is **synchronous** and only lives as long as the process that invoked it. A bare script invocation in CI, a scheduled task, or a different agent without `mavis` tools would create a cron it can't manage.

The convention: the **LLM** (mavis) sets up the monitor cron, NOT the script. After the orchestrator reports `instance created: qalos-build-...`, the driving LLM should call:

```
mavis cron create \
    --cron_name "qalos-build-<instanceName>" \
    --schedule "*/10 * * * *" \
    --prompt "<the watchdog prompt template>" \
    --session '{"mode":"sessionId","sessionId":"<this-session-id>"}'
```

The cron ticks every 10 min, SSHes in for a one-liner status, and when the build finishes downloads the build log, all 5 image files, and the serial console output to `.pi/out/gcp-build/<instanceName>/`. It also `mavis cron delete`s itself once done or after 6 hours.

The script stays focused on what it does well (create / run / cleanup). The LLM stays focused on what it does well (cross-session state, cron lifecycle, smart decisions, artifact download via SSH/SCP). Both pieces have explicit fallbacks: the script works without the LLM (just no monitor), and the LLM works without the script (manually re-runs and reads the same prompts).

### Why the LLM must own instance teardown for long builds

Layer 1 (`try/finally` in the orchestrator) is correct as the **primary** cleanup, but it has a known footgun: when the remote `do-build.sh` process tree exits, the parent SSH session does not always close promptly. The orchestrator script then sits "waiting" for up to **4 hours**, until the SSH connection eventually drops for some other reason. At that point the `try/finally` block runs and **unconditionally destroys the instance** — even if the build is healthy and running via a separate `systemd-run` unit on the same instance.

**Real incident (2026-09-04):** `qalos-build-20260904-180634` was at 45% (`BUILD_RUNNING`, compiling libLLVM AArch64) for 4 hours after `gcp-build.ps1`'s `do-build.sh` call exited early (the `set -u` bug, since fixed). The gcp-build.ps1 background task finally exited at the 4h02m mark, its `try/finally` block ran, the instance was stopped and deleted, and all 4 hours of compile progress were lost. The fix for next time:

1. **The script creates + uploads only.** The actual `m -j8` runs under `systemd-run --unit=qalos-build` on the instance, so it survives any SSH-disconnect the script might suffer.
2. **The LLM monitor cron owns the cleanup.** Its step 6 is: "After downloads: `gcloud compute instances delete qalos-build-NAME --zone=Z --quiet` if present." Only the cron knows when the build is actually done.
3. **The long-term fix is a `-NoAutoDelete` switch on gcp-build.ps1** (or a similar provider-side patch) so the script can be told to leave the instance up. Until that ships, the LLM + `systemd-run` + cron pattern is the only safe way to run a build > 10 min.

## Why four layers?

Each layer has a different failure mode it catches:

- **Layer 1** (`finally`) catches the normal cases — exit, exception, Ctrl+C. It's the primary layer.
- **Layer 2** (parent-process watchdog) catches the cases where the parent PowerShell process dies **hard** — `kill -9`, OOM, segfault. `finally{}` can't run if the process is gone.
- **Layer 3** (on-host watchdog) catches the cases where the orchestrator is alive but can't reach the instance — network partition, SSH daemon crash on the instance, the instance hung. Without this, a stuck instance could run for days.
- **Layer 4** (GH Actions cleanup) catches the cases where the GH Actions runner itself dies. The orchestrator script can't run cleanup steps if the runner is gone.

Layer 4 is DO-only because there's no GH Actions path for Aliyun yet. When you add one, copy the pattern.

## What's next

- Want to know the warm-image pattern that makes all this fast? → [Warm-image pattern](warm-image-pattern)
- Want to look at a concrete script? → [Tools reference](../reference/tools-reference)
