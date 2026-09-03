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
