# qalos Aliyun build — LLM-driven runbook

> **You are an LLM agent.** This runbook tells you exactly which
> `aliyun ecs ...` commands to call, in what order, with the right
> flags, and which `mavis cron` to set up. It is self-contained:
> you do not need to read the rest of the qalos repo.
>
> **Read [`aliyun-cli-reference.md`](aliyun-cli-reference.md) alongside this
> file** for the per-command JSON parse shape and the error code
> table. Read **[`build-cost.md`](build-cost.md)** for the cost
> numbers.
>
> **READ [`LESSONS.md`](LESSONS.md) FIRST.** It documents the
> 2026-09-10 build series failures (5 attempts, ~¥20 burned):
> Aliyun cn-hangzhou cannot reach AOSP mirrors, the
> `mirrors.aliyun.com/android.googlesource.com` endpoint is a
> fake marketing page, the 2-3 MB/s transfer rate is the real
> bottleneck, and AOSP 15 needs `g7a.16xlarge` (256 GB), NOT
> `g7a.2xlarge` (32 GB). **If you skip LESSONS.md, you will
> repeat the same 5 failures.**

## What this runbook does

Compiles qalos (an AOSP 15.0.0_r1 emulator fork) in 1–1.5 hours on
Aliyun `ecs.g7a.16xlarge` Spot, then pulls the resulting `*.img`
files back to the orchestrator and destroys the instance. The
build is launched detached via `systemd-run` on the instance, and
a `mavis cron` owns the teardown — so the agent's session can end
and the build keeps running.

## Why LLM-driven (not script-driven)

The existing `tools/aliyun-build.ps1` blocks on `ssh "bash
/tmp/do-build.sh"` for 1–6 hours. The 2026-09-04 GCP incident
(`qalos-build-20260904-180634`, AGENTS.md §5.5) is the failure
mode: the script's `try/finally` ran 4 hours in and deleted a
healthy 45%-complete build. The LLM-driven flow fixes this by
launching the build as a detached `systemd-run` unit and putting
`aliyun ecs DeleteInstance` under a `mavis cron` that survives
the agent's session.

## Prerequisites

1. **Aliyun account** in good standing. RAM ≥ 64 GB is required for
   the AOSP build; the `g7a.16xlarge` has 256 GB.
2. **Quota bump filed** at
   `https://ecs.console.aliyun.com → 配额管理 (Quota Management) →
   提交配额申请 (Submit Quota Application)`, for the `ecs.g7a`
   family, 64 vCPU. **This is on the critical path.** Approval
   is typically < 1 business day for standard types. New accounts
   are risk-limited to 8 GB by default — the smoke test will
   fail with `Forbidden.RiskControl` on any 16+ GB instance type
   until the quota is approved.
3. **Aliyun CLI** installed and configured. On Windows: run
   `.\tools\aliyun-install.ps1` then `aliyun configure`. Verify
   with `aliyun version` (expect 3.4.x) and `aliyun configure list`
   (expect a `default *` profile).
4. **SSH key** imported to Aliyun. The LLM uses Windows OpenSSH
   (`C:\Windows\System32\OpenSSH\ssh.exe`) for both `ssh` and
   `scp`. The key is the one referenced by
   `%USERPROFILE%\.ssh\id_rsa.pub` (or `id_ed25519_*`); `ssh-keygen`
   generates one if missing.
5. **Repo state**:
   - `D:\qalos\.pi\aliyun-state.json` does NOT exist on first
     run. The smoke test creates it.
   - `D:\qalos\.pi\out\aliyun-build\` is where build artifacts
     land; create it before the first build.
6. **Time budget**: ~1.5–2 hours for the full first build (sync +
   preflight + full `m` + artifact download). Sync-only preflight
   takes ~1 hour.

## State file

`D:\qalos\.pi\aliyun-state.json` (in the `.pi/` gitignored folder):

```json
{
  "region":      "cn-hangzhou",
  "zone":        "cn-hangzhou-h",
  "vpcId":       "vpc-bp1ltlwpnyw2ewhs9c0nu",
  "vpcName":     "qalos-smoke-vpc",
  "vswId":       "vsw-bp1n4709hyzvig1cemz10",
  "vswName":     "qalos-smoke-vsw",
  "sgId":        "sg-bp1fuf9b31u6udgij7en",
  "sgName":      "qalos-smoke-sg",
  "keyPairName": "qalos-smoke-key",
  "imageId":     "ubuntu_22_04_x64_20G_alibase_20260810.vhd",
  "warmImageId": "m-bp1xxxxxxxxxxxx",  // added by setup-base
  "warmImageName": "qalos-build-warm",
  "updatedAt":   "2026-09-09T15:00:00Z"
}
```

The LLM reads it on every build; it never writes it. Only the
smoke test and setup-base write the file. If the file is missing
or invalid, run the smoke test first.

## Per-build state file (NEW 2026-09-09)

Separate from the INFRA state file above, the LLM-driven Phase 4
flow maintains a PER-BUILD state file at
`D:\qalos\.pi\aliyun-build-state.json`. This is the canonical
record for one build attempt — instance ID, public IP, SSH
credentials, artifact URL, mavis cron ID, status, and the
reasoning behind the build's choices. The cron and the next agent
both read it.

**Why a separate file?** The INFRA file is read by the LLM and
written by the smoke test / setup-base. The BUILD file is written
by the LLM as the build progresses, and read by the cron and any
follow-up agent. Mixing the two would require write coordination
between the LLM and the smoke test. The separation also keeps the
infra file immutable across builds (only the smoke test updates
it), which makes the infra state easier to reason about.

**Schema v1** (`qalos://aliyun-build-state/v1`):

| Path | Type | Purpose |
|---|---|---|
| `buildId` | string | `qalos-build-YYYY-MM-DD-HHMMSS` — the build's stable name |
| `status` | enum | `preparing` → `launching` → `syncing` → `preflight` → `building` → `done` / `failed` → `torn_down` |
| `instance.id` | string | Aliyun `i-bp...`; set after `RunInstances` |
| `instance.publicIp` | string | Public IP; set after `DescribeInstances` shows `Status=Running` |
| `instance.type`, `vCPU`, `memoryGB`, `spot`, `maxRuntimeMinutes` | various | What was launched and why |
| `ssh.user`, `ssh.authMethod` (`password` or `keypair`) | string | SSH user; auth method chosen for THIS build |
| `ssh.password` | string | SENSITIVE: only when `authMethod=password`. File is in `.pi/` (gitignored) by design |
| `artifact.token` | uuid4 | The HTTP server's token; written to `/tmp/qalos-artifacts-token.txt` on the instance |
| `artifact.url` | string | `http://<publicIp>:<port>/<token>/` — set once the server is up |
| `mavisCron.id`, `mavisCron.name` | string | Set after `mavis cron create`; cron self-deletes with this id |
| `outputs.rootDir`, `outputs.userDataFile`, etc. | path | Where the artifacts, UserData, and cron prompt live on the host |
| `decisions.whyXxx` | string | Human-readable rationale for non-obvious choices (instance type, auth method, etc.) |
| `stateTransitions[]` | array of `{at, to, note}` | Append-only history of every status change; the next agent reads this to recover |
| `nextAgentActions[]` | string[] | Recovery checklist — "if you are a fresh agent, do steps 1..N" |

**Lifecycle:**

1. **Created at Phase 4 launch start** (status: `preparing`), before
   `aliyun ecs RunInstances`. Password is generated; `instance.id` is
   `null` until `RunInstances` returns.
2. **Updated after every state transition.** Each transition appends
   to `stateTransitions[]` with `at`, `to`, and a `note`. The next
   agent (or a human reading the file) sees the full history.
3. **Read by the mavis cron** on every tick. The cron's prompt
   embeds the `instance.id`, `publicIp`, and `artifact.url` from
   the state file so the cron does not re-discover them.
4. **Read by any follow-up agent** if the original session dies
   mid-build. The `nextAgentActions[]` array is the recovery
   checklist: where the build is, what the cron expects, how to
   tear down.

**Sensitive fields.** `ssh.password` is in plaintext. The file is
in `D:\qalos\.pi\` which is gitignored. The password is only
valid for the lifetime of the build instance (≤ 6 h). For a
multi-day standing environment, switch to keypair auth and remove
the `password` field from the state.

**The state file is gitignored but the runbook that documents it
is not.** Future builds that don't follow this runbook will not
maintain the state file — and that is the failure mode the state
file was created to prevent.

## Phase 2 — Smoke test (LLM-driven, Bash)

The smoke test creates the VPC/vSwitch/SG/KeyPair, launches the
smallest in-stock ECS in `cn-hangzhou / cn-hangzhou-h`, confirms
it reaches `Running`, deletes it, and writes the state file.

```text
# Pseudocode for the LLM. Use the Bash tool. Adapt to the
# actual aliyun CLI JSON output (see aliyun-cli-reference.md).

# 1. Verify CLI + auth
aliyun version                              # → 3.4.x
aliyun configure list                       # → default *

# 2. Find the smallest in-stock instance type
in_stock=$(aliyun ecs DescribeAvailableResource \
    --RegionId cn-hangzhou --ZoneId cn-hangzhou-h \
    --DestinationResource InstanceType \
    | jq -r '.AvailableZones.AvailableZone
              .AvailableResources.AvailableResource[].SupportedResources
              .SupportedResource[] | select(.Status=="Available") | .Value')
# Filter out exotic families (GPU, bare-metal)
# Look up specs, pick smallest by RAM then vCPU
# Result: e.g. ecs.e-c2m1.small or ecs.u1-c1m2.large

# 3. Create or reuse VPC / vSwitch / SG / KeyPair (idempotent)
#    Look up by name first; create if missing.
#    Authorize SSH 22/22 from 0.0.0.0/0 on the SG.
#    Import the local SSH public key as the KeyPair.

# 4. Find the latest Ubuntu 22.04 image
image_id=$(aliyun ecs DescribeImages \
    --RegionId cn-hangzhou --ImageOwnerAlias system \
    --OSType linux --Architecture x86_64 --PageSize 100 \
    | jq -r '.Images.Image | map(select(.OSName | test("ubuntu_22.04";"i")))
              | sort_by(.CreationTime) | reverse | .[0].ImageId')

# 5. Launch the probe instance
instance_id=$(aliyun ecs RunInstances \
    --RegionId cn-hangzhou --ImageId "$image_id" \
    --InstanceType "$chosen_type" \
    --SecurityGroupId "$sg_id" --VSwitchId "$vsw_id" \
    --InstanceName "qalos-smoke-$(date +%H%M%S)" \
    --InstanceChargeType PostPaid \
    --InternetMaxBandwidthOut 5 --InternetChargeType PayByTraffic \
    --SystemDisk.Category cloud_essd --SystemDisk.Size 40 \
    --KeyPairName "$key_pair_name" --Amount 1 \
    | jq -r '.InstanceIdSets.InstanceIdSet[0]')

# 6. Wait for Running + public IP (≤ 90s)
for i in $(seq 1 18); do
    inst=$(aliyun ecs DescribeInstances \
        --RegionId cn-hangzhou --InstanceIds "['$instance_id']" \
        | jq -r '.Instances.Instance[0] | "\(.Status)|\(.PublicIpAddress.IpAddress[0] // empty)"')
    status="${inst%%|*}"; ip="${inst#*|}"
    [[ "$status" == "Running" && -n "$ip" ]] && break
    sleep 5
done
[[ -z "$ip" ]] && { echo "FATAL: instance never became Running"; \
    aliyun ecs StopInstance ...; aliyun ecs DeleteInstance ...; exit 1; }

# 7. Verify SSH
for i in $(seq 1 30); do
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$ip" "echo ready" 2>/dev/null \
        && break
    sleep 5
done

# 8. Tear down (always, even on failure — trap)
trap 'aliyun ecs StopInstance ...; aliyun ecs DeleteInstance ...' EXIT
aliyun ecs StopInstance --RegionId cn-hangzhou --InstanceId "$instance_id"
# Wait for Stopped (the DeleteInstance on Running → SDK.ServerError gotcha)
for i in $(seq 1 20); do
    status=$(aliyun ecs DescribeInstances ... | jq -r '.Instances.Instance[0].Status')
    [[ "$status" == "Stopped" ]] && break
    sleep 3
done
aliyun ecs DeleteInstance --RegionId cn-hangzhou --InstanceId "$instance_id" --Force true

# 9. Write the state file
mkdir -p D:\qalos\.pi
cat > D:\qalos\.pi\aliyun-state.json <<EOF
{
  "region": "cn-hangzhou",
  "zone": "cn-hangzhou-h",
  "vpcId": "$vpc_id", "vpcName": "qalos-smoke-vpc",
  "vswId": "$vsw_id", "vswName": "qalos-smoke-vsw",
  "sgId": "$sg_id", "sgName": "qalos-smoke-sg",
  "keyPairName": "$key_pair_name",
  "imageId": "$image_id",
  "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
```

**Acceptance:** `Test-Path D:\qalos\.pi\aliyun-state.json` →
True; the file has all 9 keys; `aliyun ecs DescribeInstances
--InstanceIds "[$instance_id]"` returns 0 instances.

**Failure modes:**
- `Forbidden.RiskControl` on `RunInstances`: the account is
  risk-limited. The LLM reports the quota-bump URL and stops.
  Phases 3-5 are blocked.
- `SDK.ServerError` (transient): retry 4× with 3s backoff (the
  `aliyon()` pattern). If still failing, exit cleanly.
- SSH never comes up: the `trap` deletes the instance and the
  LLM reports the failure to the user.

## Phase 3 — Warm image (LLM-driven, Bash)

The warm image is an Ubuntu 22.04 base + AOSP build deps, captured
as an Aliyun custom image. Every build launches from it.

```text
# 1. Read the state file
state=$(cat D:\qalos\.pi\aliyun-state.json)
vpc_id=$(jq -r .vpcId <<< "$state")
vsw_id=$(jq -r .vswId <<< "$state")
sg_id=$(jq -r .sgId <<< "$state")
kp_name=$(jq -r .keyPairName <<< "$state")
image_id=$(jq -r .imageId <<< "$state")

# 2. Launch a small base ECS (NOT the build instance; this is the
#    warm-image template). Cheap, in-stock, fits the 8 GB limit.
base_id=$(aliyun ecs RunInstances \
    --RegionId cn-hangzhou --ImageId "$image_id" \
    --InstanceType ecs.u1-c1m1.large \
    --SecurityGroupId "$sg_id" --VSwitchId "$vsw_id" \
    --InstanceName "qalos-base-$(date +%H%M%S)" \
    --InstanceChargeType PostPaid \
    --InternetMaxBandwidthOut 5 --InternetChargeType PayByTraffic \
    --SystemDisk.Category cloud_essd --SystemDisk.Size 100 \
    --KeyPairName "$kp_name" --Amount 1 \
    | jq -r '.InstanceIdSets.InstanceIdSet[0]')

# 3. Wait for Running + public IP (same loop as Phase 2)

# 4. scp + run setup-droplet.sh
scp D:/qalos/tools/setup-droplet.sh "root@$ip:/tmp/setup-droplet.sh"
ssh -o StrictHostKeyChecking=no "root@$ip" "bash /tmp/setup-droplet.sh"

# 5. Shutdown for clean image capture
ssh -o StrictHostKeyChecking=no "root@$ip" "shutdown -h now"
# Wait for Stopped

# 6. CreateImage
warm_image_id=$(aliyun ecs CreateImage \
    --RegionId cn-hangzhou --InstanceId "$base_id" \
    --ImageName qalos-build-warm \
    --Description "qalos warm AOSP build image" \
    | jq -r .ImageId)

# 7. Delete the base ECS (trap)
aliyun ecs StopInstance ... ; aliyun ecs DeleteInstance ...

# 8. Update the state file with warmImageId
jq --arg id "$warm_image_id" --arg name "qalos-build-warm" \
    '. + {warmImageId: $id, warmImageName: $name, updatedAt: (now|todate)}' \
    D:\qalos\.pi\aliyun-state.json > D:\qalos\.pi\aliyun-state.json.tmp
mv D:\qalos\.pi\aliyun-state.json.tmp D:\qalos\.pi\aliyun-state.json
```

**Acceptance:** `aliyun ecs DescribeImages --RegionId cn-hangzhou
--ImageName qalos-build-warm` returns the image; size 8-15 GB.

**Standing cost:** ¥8-12/month at ESSD PL1. The root AGENTS.md §6
quotes ¥1/month — that is stale and was corrected in this run.

## Phase 4 — Per-build (the actual LLM-driven flow)

This is the main event. The LLM:

1. Reads the state file.
2. `RunInstances` for the build ECS (64 vCPU / 256 GB / Spot /
   500 GB ESSD PL2).
3. Waits for Running + public IP.
4. `scp` do-build.sh, qalos-env.sh to the instance.
5. Writes the systemd unit on the instance and starts it detached
   via `systemd-run --unit=qalos-build`.
6. Sets up a `mavis cron` to own teardown.
7. Disconnects. The cron takes over.

### 4.1 Launch the build ECS

```text
state=$(cat D:\qalos\.pi\aliyun-state.json)
warm_image_id=$(jq -r .warmImageId <<< "$state")
vsw_id=$(jq -r .vswId <<< "$state")
sg_id=$(jq -r .sgId <<< "$state")
kp_name=$(jq -r .keyPairName <<< "$state")

instance_name="qalos-build-$(date +%Y%m%d-%H%M%S)"
build_id=$(aliyun ecs RunInstances \
    --RegionId cn-hangzhou --ImageId "$warm_image_id" \
    --InstanceType ecs.g7a.16xlarge \
    --InstanceChargeType PostPaid --SpotStrategy SpotAsPriceGo \
    --SecurityGroupId "$sg_id" --VSwitchId "$vsw_id" \
    --InstanceName "$instance_name" \
    --InternetMaxBandwidthOut 10 --InternetChargeType PayByTraffic \
    --SystemDisk.Category cloud_essd --SystemDisk.Size 500 \
    --KeyPairName "$kp_name" --Amount 1 \
    | jq -r '.InstanceIdSets.InstanceIdSet[0]')

# Save the build id — the cron needs it
echo "$build_id" > D:\qalos\.pi\out\aliyun-build\$instance_name.id
echo "$instance_name" > D:\qalos\.pi\out\aliyun-build\$instance_name.name
```

**Note on the spot strategy:** Aliyun's `SpotStrategy=SpotAsPriceGo`
is set on the same `RunInstances` call as `--InstanceChargeType
PostPaid`. The CLI does not have a separate `--Spot` flag.

**Note on disk size:** the minimum for ESSD PL2 is 461 GB. 500 GB
is the smallest that lands on PL2 automatically. If the user later
wants PL1, drop to 40 GB (PL1 min) — but the Java compile phase
will run ~20 % slower.

### 4.2 Wait for Running + public IP

```text
for i in $(seq 1 18); do
    inst=$(aliyun ecs DescribeInstances \
        --RegionId cn-hangzhou --InstanceIds "['$build_id']" \
        | jq -r '.Instances.Instance[0] | "\(.Status)|\(.PublicIpAddress.IpAddress[0] // empty)"')
    status="${inst%%|*}"; ip="${inst#*|}"
    [[ "$status" == "Running" && -n "$ip" ]] && break
    sleep 5
done
[[ -z "$ip" ]] && { echo "FATAL: instance never became Running"; \
    aliyun ecs StopInstance ...; aliyun ecs DeleteInstance ...; exit 1; }
echo "instance ready: $build_id @ $ip"
```

### 4.3 scp the on-host files

```text
# 1. Write the env file locally
cat > /tmp/qalos-env.sh <<EOF
QALOS_REPO_URL='https://github.com/bramburn/qalos.git'
AOSP_TAG='android-15.0.0_r1'
BUILD_TARGET='qalos_emulator'
BUILD_RELEASE='trunk_staging'
BUILD_VARIANT='userdebug'
MAX_RUNTIME_MINUTES='180'
QALOS_USE_TUNA_MIRROR='1'
# Public IP, passed to the on-host artifact server so the URL
# file points at the right address.
QALOS_PUBLIC_IP='$ip'
# Uncomment to stop after the preflight (Phase 4 = preflight only):
# QALOS_STOP_AFTER_PREFLIGHT='1'
EOF

# 2. scp
scp D:/qalos/tools/do-build.sh "root@$ip:/tmp/do-build.sh"
scp D:/qalos/tools/aliyun/qalos-serve-artifacts.py "root@$ip:/opt/qalos/qalos-serve-artifacts.py"
scp /tmp/qalos-env.sh "root@$ip:/tmp/qalos-env.sh"

# 3. chmod the artifact server
ssh -o StrictHostKeyChecking=no "root@$ip" "chmod +x /opt/qalos/qalos-serve-artifacts.py"
```

### 4.4 Write the systemd unit on the instance and start it detached

The unit has two parts: the main build (`ExecStart=`) and the
post-build HTTP server (`ExecStartPost=`) that exposes the
artifacts over a token-gated URL.

```text
ssh -o StrictHostKeyChecking=no "root@$ip" <<'REMOTE'
set -e
cat > /etc/systemd/system/qalos-build.service <<'UNIT'
[Unit]
Description=qalos AOSP build
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/tmp/qalos-env.sh
ExecStart=/bin/bash /tmp/do-build.sh
# After the build finishes, start the token-gated HTTP server
# that serves the artifacts. The server reads its URL from
# /tmp/qalos-artifacts-url.txt; the cron and the user both
# read this file.
ExecStartPost=/bin/bash -c 'set -e; \
    TOKEN=$$(python3 -c "import uuid; print(uuid.uuid4())"); \
    QALOS_PUBLIC_IP="$${QALOS_PUBLIC_IP:-localhost}" \
    nohup python3 /opt/qalos/qalos-serve-artifacts.py \
        --port 8080 \
        --token "$$TOKEN" \
        --directory /root/aosp/out/target/product/qalos_emulator \
        --url-file /tmp/qalos-artifacts-url.txt \
        --pid-file /tmp/qalos-serve-artifacts.pid \
        --log-file /var/log/qalos-serve-artifacts.log \
        >/dev/null 2>&1 &'
TimeoutStopSec=600
KillMode=process
# On SIGTERM (the on-host watchdog or spot reclaim), also kill
# the HTTP server. The PID file lets the kill be precise.
ExecStop=/bin/bash -c 'if [ -f /tmp/qalos-serve-artifacts.pid ]; then \
    kill $(cat /tmp/qalos-serve-artifacts.pid) 2>/dev/null || true; fi'
StandardOutput=append:/var/log/qalos-build.log
StandardError=append:/var/log/qalos-build.log

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
REMOTE

# Start it detached. The agent's SSH connection ends here, but
# the systemd unit keeps running. do-build.sh's own
# MAX_RUNTIME_MINUTES=180 watchdog is the hard upper bound.
ssh -o StrictHostKeyStopping=no "root@$ip" \
    "systemd-run --unit=qalos-build --service-type=oneshot /bin/bash /tmp/do-build.sh"
```

**Why `systemd-run --service-type=oneshot`?** It mirrors the
`qalos-build.service` unit above, but transiently. If the service
file is missing for any reason, the run will fail loudly instead
of running in the foreground.

**Why `KillMode=process`?** If spot is reclaimed and systemd tries
to stop the unit, only the main process (the bash) is killed;
child processes (java, make) are also killed because they're in
the same process group. The instance state goes to `Stopped` and
the cron sees it.

**Why `ExecStartPost=...qalos-serve-artifacts.py`?** The
artifacts (3-5 GB of `*.img` plus the build log) need to leave
the instance. The previous design pulled them via `scp` from the
orchestrator, but `scp` requires the SSH key on the orchestrator
and adds egress cost. The HTTP server exposes the artifacts over
a token-gated URL on the public IP. The cron and the user both
read `/tmp/qalos-artifacts-url.txt` and use `curl` (or a browser
for the human) to download. See
[qalos-serve-artifacts.py](qalos-serve-artifacts.py) for the
server implementation and the security model.

**Why `ExecStop=...qalos-serve-artifacts.pid`?** When the
on-host watchdog calls `shutdown -h now`, systemd first runs
`ExecStop=` (which kills the HTTP server) and only then powers
the instance off. Without this, the server would get SIGKILL on
shutdown and the URL file would point at a dead URL.

### 4.5 Set up the mavis cron

The cron owns the build lifetime. It runs in a separate session,
so it survives the agent's session death. It downloads the
artifacts over HTTP (via the token-gated URL the systemd unit's
`ExecStartPost=` wrote) instead of via `scp` — this means the
user can also open the URL in a browser to grab a single file
without `scp`-ing the whole 3-5 GB.

```text
# Build the prompt template. See "Cron tick logic" below.
cat > /tmp/qalos-cron-prompt.md <<'PROMPT'
You are the monitor for the qalos AOSP build on Aliyun.
Instance name: $INSTANCE_NAME
Instance ID:   $BUILD_ID
Public IP:     $IP
Region:        cn-hangzhou

Tick steps (in order):
1. SSH in: ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@$IP \
   "systemctl is-active qalos-build"
2. If "active": skip. If "inactive" or "failed":
   a. Read the artifacts URL file:
      URL=$(ssh -o StrictHostKeyChecking=no root@$IP "cat /tmp/qalos-artifacts-url.txt")
      If "pending" or empty: the server hasn't started yet; sleep 30s and retry.
   b. Download the build log via the URL:
      curl -fSL "$URL/var/log/qalos-build.log" \
          -o D:/qalos/.pi/out/aliyun-build/$INSTANCE_NAME/build.log
   c. Download the three artifacts via the URL:
      for f in system.img boot.img userdata.img; do
          curl -fSL "$URL/$f" -o D:/qalos/.pi/out/aliyun-build/$INSTANCE_NAME/$f
      done
   d. Also grab the preflight log if it exists:
      curl -fSL "$URL/../root/aosp/.qalos-logs/preflight.log" \
          -o D:/qalos/.pi/out/aliyun-build/$INSTANCE_NAME/preflight.log || true
   e. Tear down the instance:
      aliyun ecs StopInstance --RegionId cn-hangzhou --InstanceId $BUILD_ID
      (wait for Stopped)
      aliyun ecs DeleteInstance --RegionId cn-hangzhou --InstanceId $BUILD_ID --Force true
   f. Delete this cron: mavis cron delete $CRON_ID
   g. Report PASS/FAIL to the user with the build log summary AND
      the artifacts URL (so the user can re-download any file in a
      browser if they want to).
3. If the instance is in Stopped state (spot reclaim or watchdog):
   same as step 2 — try to read /tmp/qalos-artifacts-url.txt
   one last time (it may still be on the local disk), then
   download, tear down, delete cron.
4. If 6 hours have elapsed since cron creation:
   a. Tail the build log to surface the failure.
   b. Leave the instance running for the user to inspect.
   c. Delete this cron: mavis cron delete $CRON_ID
   d. Report the timeout to the user.

The on-host do-build.sh has MAX_RUNTIME_MINUTES=180 (3 h), so
the 6 h cron cap is the last-resort belt; the on-host watchdog
should have force-shut the instance by then.
PROMPT

# Create the cron
mavis cron create \
    --cron_name "qalos-build-$instance_name" \
    --schedule "*/10 * * * *" \
    --prompt "$(cat /tmp/qalos-cron-prompt.md)" \
    --session '{"mode":"sessionId","session_id":"<this-session-id>"}'
```

### 4.6 Disconnect

That's the whole per-build LLM flow. The agent's session can end
here. The cron ticks every 10 min; the build runs in the background;
the artifacts are served at the URL in `/tmp/qalos-artifacts-url.txt`
and the cron downloads them via `curl` once the build is done.

## Downloading artifacts

After the build finishes, the systemd unit's `ExecStartPost=`
starts [`qalos-serve-artifacts.py`](qalos-serve-artifacts.py) on
the build instance. The server:

- listens on `0.0.0.0:8080` (or whatever port the systemd unit
  passes via `--port`)
- serves files from `/root/aosp/out/target/product/qalos_emulator`
  (the AOSP build output) under a single URL prefix `/<token>/`,
  where `<token>` is a uuid4 generated at start
- writes the public URL to `/tmp/qalos-artifacts-url.txt` (e.g.
  `http://114.215.200.49:8080/3f2a-4b1c-.../`)
- 404s anything that does not start with the token

**Download via `curl` (the cron, or an automated script):**

```bash
URL=$(ssh root@$IP "cat /tmp/qalos-artifacts-url.txt")
curl -fSL "$URL/system.img" -o system.img
curl -fSL "$URL/boot.img"   -o boot.img
curl -fSL "$URL/userdata.img" -o userdata.img
curl -fSL "$URL/var/log/qalos-build.log" -o build.log
```

**Download via a browser (the user):**

1. SSH into the instance and read the URL:
   ```bash
   ssh root@$IP "cat /tmp/qalos-artifacts-url.txt"
   ```
2. Paste the URL into a browser. The browser shows a directory
   listing (if the token prefix matches); click any file to
   download it. The browser also lets you download a single file
   without `scp`-ing the whole 3-5 GB.

**Security model:** the server binds to the public IP and the
token is a uuid4. The instance lives for ~5-10 min after the
build finishes (until the cron tears it down), so the
exposure window is short. A port-scan + uuid4-guess in that
window is infeasible. The user is the only entity that knows
the token (it appears in `/tmp/qalos-artifacts-url.txt` on the
instance and in the cron's prompt).

**Why HTTP instead of `scp`?** `scp` requires the SSH key on
the orchestrator and is awkward for the user (they have to
shell into the orchestrator and run an `scp` command). HTTP
is the natural shape: the user pastes a URL in a browser, the
cron runs `curl`, both are obvious.

## Cron tick logic (the prompt the agent uses)

The cron is just another agent invocation. It needs the right
prompt. The template above is a starting point; refine it to
include the exact `instance_id`, `public_ip`, and `cron_id`.

The cron should:

1. **Never block.** Read `systemctl is-active qalos-build` first;
   if `active`, return immediately. The build takes 1-1.5 hours;
   the cron should not interfere.
2. **Download everything on success.** The build log AND the
   three `*.img` files, via the token-gated URL (see
   "Downloading artifacts" above). The `curl -fSL` pattern
   handles redirects and 404s gracefully.
3. **Tear down the instance ALWAYS** on inactive/failed/stopped.
   The on-host watchdog only calls `shutdown -h now`; the
   instance is in `Stopped` state, not deleted. The cron must
   call `DeleteInstance` to avoid standing cost.
4. **Self-delete** with `mavis cron delete $CRON_ID` once the
   instance is gone. Crons do not persist across builds.
5. **6-hour hard cap.** If the cron has been ticking for 6 hours
   and the build is still running, leave the instance running
   for the user to inspect (the on-host watchdog should have
   killed it by 3 hours; 6 hours is "something else is wrong"
   territory). Delete the cron, alert the user.
6. **Surface the URL to the user.** When the build finishes,
   the cron's final report to the user should include the
   artifacts URL — the user can then re-download any file in
   a browser.

## Phase 5 — Phase 4 + skip the preflight stop

For the **first real build** (after the quota is approved), Phase 4
is the right starting point, with `QALOS_STOP_AFTER_PREFLIGHT`
**unset** (commented out in `qalos-env.sh`). The build runs the
preflight (5-15 min) and then the full `m -j64` (1-1.5 h). Total
wall time: 1.5-2 hours. Total cost: ¥6-10 on spot.

For **subsequent builds**, Phase 4 is the same.

For **debug builds** (the user wants to stop after preflight to
inspect a metalava issue), set `QALOS_STOP_AFTER_PREFLIGHT=1` in
the env file. The build runs preflight only, exits 0, the cron
sees `inactive`, downloads the preflight log, tears down. Cost:
~¥1 (15 min of spot compute + 15 min of disk).

## Failure modes (the LLM must handle all of these)

| Failure | What the LLM sees | What the LLM does |
|---|---|---|
| `RunInstances` → `Forbidden.RiskControl` | JSON `Code: "Forbidden.RiskControl"` in `aliyun` stdout | Surface the quota-bump URL. No instance is running. |
| `RunInstances` → `SDK.ServerError` (transient) | Bare `ERROR: SDK.ServerError` on stderr, JSON detail in stdout | Retry 4× with 3s backoff. If still failing, exit. |
| SSH never comes up | `ssh` times out 30 times in 2.5 min | `trap` deletes the instance. Report to user. |
| `repo sync` rate-limited (HTTP 429) | `do-build.sh` logs, retries 3×, j1 fallback | On-host watchdog at 180 min shuts the instance. Cron downloads partial log, tears down. |
| AOSP compile error (missing @FlaggedApi) | Preflight metalava fails (5-15 min) | Unit is `inactive`, cron sees the failure, downloads the preflight log, tears down. |
| Full `m` fails (e.g. OOM) | Unit is `inactive` after 1-1.5 h | Cron downloads the full build log, tears down. |
| Spot reclaim | Instance state → `Stopped`; build lost | Cron sees `Stopped`, downloads any partial artifacts, tears down. |
| `MAX_RUNTIME_MINUTES=180` exceeded | On-host `shutdown -h now` fires | Cron sees `Stopped`, downloads partial log, tears down. |
| Agent session dies | (N/A — the cron is in a separate session) | Cron continues. Eventually tears down. |
| Cron dies | (N/A — the on-host watchdog still works) | The on-host `shutdown -h now` at 180 min prevents the worst case. Worst case: one build billed for 6 h (¥18 on spot). |
| Spot price spikes (`SpotAsPriceGo` follows the market) | Instance may be reclaimed at any time | Same as the spot reclaim row. The Aliyun spot price for `g7a.16xlarge` is typically stable; this is a corner case. |

## AOSP 15 API check (do-build.sh)

`tools/do-build.sh` is the single source of truth for the on-host
build. The LLM-driven flow uses it unchanged. All six AOSP APIs
it calls are correct for `android-15.0.0_r1`:

1. `repo init -u <manifest> -b main` (line 111). The qalos repo IS
   the manifest.
2. `repo sync -c -j$REPO_SYNC_JOBS --no-tags --no-clone-bundle`
   (line 139). With `QALOS_USE_TUNA_MIRROR=1`, `REPO_SYNC_JOBS=4`
   (TUNA rate-limits at 4 concurrent git fetches).
3. `apply-qalos.sh` (line 173-180). The 3 qalos patches apply
   cleanly against real AOSP 15 source.
4. `lunch qalos_emulator-trunk_staging-userdebug` (line 189).
   AOSP 15 requires 3-part combos.
5. `m -jN frameworks/base/api:api-stubs-docs-non-updatable` (line
   202). The preflight metalava target.
6. `m -jN` (line 216). The full build.

`QALOS_USE_TUNA_MIRROR=1` and `QALOS_STOP_AFTER_PREFLIGHT=1` are
new env vars added to `do-build.sh` in Phase 1 of the 2026-09-09
implementation turn. Both are additive (default-off) and do not
break the existing flow.

## Deprecation note

**`tools/aliyun-build.ps1` and `scripts/aliyun-build.sh` were
removed 2026-09-09** (use `mavis-trash` to recover if needed).
They had three known bugs (B-1: `$ddidx` typo in the wait loop;
B-2: missing `$sgId`/`$vswId` load from the state file; B-3:
blocking on SSH for 1-6 hours, the same shape that bit the GCP
path on 2026-09-04). The LLM-driven runbook is the only path;
the smoke test (`tools/aliyun-smoke-test.ps1`,
`scripts/aliyun-smoke-test.sh`) and setup-base
(`tools/aliyun-setup-base.ps1`, `scripts/aliyun-setup-base.sh`)
remain on disk for users who prefer scripts.

## Quick command reference

| Step | aliyun CLI command |
|---|---|
| List in-stock types | `aliyun ecs DescribeAvailableResource --RegionId cn-hangzhou --ZoneId cn-hangzhou-h --DestinationResource InstanceType` |
| Launch build ECS | `aliyun ecs RunInstances --ImageId $warm_image_id --InstanceType ecs.g7a.16xlarge --SpotStrategy SpotAsPriceGo --SystemDisk.Category cloud_essd --SystemDisk.Size 500 ...` |
| Wait for Running | `aliyun ecs DescribeInstances --InstanceIds "[$build_id]"` (loop until Status=Running + PublicIpAddress set) |
| Stop | `aliyun ecs StopInstance --InstanceId $build_id` (wait for Stopped) |
| Delete | `aliyun ecs DeleteInstance --InstanceId $build_id --Force true` |
| Create image | `aliyun ecs CreateImage --InstanceId $base_id --ImageName qalos-build-warm` |

See **[`aliyun-cli-reference.md`](aliyun-cli-reference.md)** for the
full reference with JSON parse shape and error code table.
