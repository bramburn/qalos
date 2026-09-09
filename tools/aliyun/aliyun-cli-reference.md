# qalos Aliyun CLI reference

> Concise reference of every `aliyun ecs ...` command the
> [LLM runbook](AGENTS.md) uses. Format: command, JSON parse shape,
> the most common error codes, and the fix for each.

> **Read alongside:** [AGENTS.md](AGENTS.md) for the high-level
> flow, [build-cost.md](build-cost.md) for the cost numbers.

## Conventions

- The aliyun CLI prints JSON on stdout and a one-line `ERROR: SDK.ServerError`
  on stderr when something fails. **Always parse stdout; the stderr is
  useless** (see root AGENTS.md §7.5).
- The Bash pattern in the runbook is `cmd | jq -r '.path.to.field'`.
  If the JSON is missing, `jq` exits non-zero and the runbook's
  `if ...; then ...; else exit 1; fi` catches it.
- The Bash retry pattern (mirrors `aliyon()` in the .sh twins) is:

  ```bash
  for attempt in 1 2 3 4; do
      out=$(aliyun ecs SomeCommand ... 2>&1)
      json=$(printf '%s' "$out" | grep -m1 -oE '\{.*\}' || true)
      if [[ -n "$json" ]] && printf '%s' "$json" | jq . >/dev/null 2>&1; then
          # success
          printf '%s' "$json"
          break
      fi
      if [[ "$out" =~ SDK\.ServerError|Throttling|ServiceUnavailable|InternalError ]]; then
          if [[ $attempt -lt 4 ]]; then sleep 3; continue; fi
      fi
      echo "FATAL: aliyun ecs SomeCommand failed:" >&2
      printf '%s\n' "$out" | grep -E 'ERROR|error|Code' | head -4 >&2
      exit 1
  done
  ```

## The commands

### `DescribeAvailableResource`

Check what's in stock in a zone.

```bash
aliyun ecs DescribeAvailableResource \
    --RegionId cn-hangzhou --ZoneId cn-hangzhou-h \
    --DestinationResource InstanceType
```

JSON parse:
```json
{
  "AvailableZones": {
    "AvailableZone": [
      {
        "AvailableResources": {
          "AvailableResource": [
            {
              "Type": "InstanceType",
              "SupportedResources": {
                "SupportedResource": [
                  { "Value": "ecs.g7a.large", "Status": "Available" },
                  { "Value": "ecs.g7a.xlarge", "Status": "Available" }
                ]
              }
            }
          ]
        }
      }
    ]
  }
}
```

jq filter for the in-stock IDs:
```bash
... | jq -r '.AvailableZones.AvailableZone[].AvailableResources
              .AvailableResource[].SupportedResources.SupportedResource[]
              | select(.Status=="Available") | .Value'
```

**Gotcha:** `--InstanceType '["ecs.g7a.16xlarge"]'` as a filter is
unreliable and silently returns empty. Drop the filter, get the full
list, filter in `jq` (see root AGENTS.md §7.2).

### `DescribeInstanceTypes`

Look up specs for a set of instance type IDs.

```bash
aliyun ecs DescribeInstanceTypes --InstanceTypes '["ecs.g7a.large","ecs.g7a.xlarge"]'
```

JSON parse:
```json
{
  "InstanceTypes": {
    "InstanceType": [
      { "InstanceTypeId": "ecs.g7a.large", "CpuCoreCount": 2, "MemorySize": 8,
        "InstanceTypeFamily": "ecs.g7a", "GPU": 0 },
      ...
    ]
  }
}
```

### `DescribeImages`

Find the most recent Ubuntu 22.04 image.

```bash
aliyun ecs DescribeImages \
    --RegionId cn-hangzhou --ImageOwnerAlias system \
    --OSType linux --Architecture x86_64 --PageSize 100
```

jq filter for the latest Ubuntu 22.04:
```bash
... | jq -r '.Images.Image
              | map(select(.OSName | test("ubuntu";"i") and
                            (.  | test("22.04";"i"))) )
              | sort_by(.CreationTime) | reverse | .[0].ImageId'
```

### `vpc DescribeVpcs` / `vpc CreateVpc`

Idempotent VPC lookup-or-create:

```bash
existing=$(aliyun vpc DescribeVpcs --RegionId cn-hangzhou --VpcName qalos-smoke-vpc \
    | jq -r '.Vpcs.Vpc[0].VpcId // empty')
if [[ -z "$existing" ]]; then
    vpc_id=$(aliyun vpc CreateVpc --RegionId cn-hangzhou \
        --CidrBlock 172.16.0.0/16 --VpcName qalos-smoke-vpc \
        --Description "qalos smoke test VPC" \
        | jq -r .VpcId)
else
    vpc_id="$existing"
fi
```

### `vpc DescribeVSwitches` / `vpc CreateVSwitch`

Idempotent vSwitch lookup-or-create (zone-scoped):

```bash
existing=$(aliyun vpc DescribeVSwitches --RegionId cn-hangzhou \
    --VpcId "$vpc_id" --VSwitchName qalos-smoke-vsw \
    | jq -r '.VSwitches.VSwitch[0].VSwitchId // empty')
```

### `ecs DescribeSecurityGroups` / `ecs CreateSecurityGroup` / `ecs AuthorizeSecurityGroup`

Idempotent SG lookup-or-create, then authorize SSH 22/22 from 0.0.0.0/0:

```bash
aliyun ecs AuthorizeSecurityGroup \
    --RegionId cn-hangzhou --SecurityGroupId "$sg_id" \
    --IpProtocol tcp --PortRange 22/22 \
    --SourceCidrIp 0.0.0.0/0 \
    --Description "qalos SSH" >/dev/null 2>&1 || true   # idempotent
```

### `ecs DescribeKeyPairs` / `ecs ImportKeyPair`

Idempotent KeyPair lookup-or-import:

```bash
pubkey_text=$(cat "$HOME/.ssh/id_rsa.pub")
aliyun ecs ImportKeyPair --RegionId cn-hangzhou \
    --KeyPairName qalos-smoke-key --PublicKeyBody "$pubkey_text"
```

### `ecs RunInstances`

The core launch call. Returns an `InstanceId`:

```bash
aliyun ecs RunInstances \
    --RegionId cn-hangzhou --ImageId "$image_id" \
    --InstanceType ecs.g7a.16xlarge \
    --InstanceChargeType PostPaid --SpotStrategy SpotAsPriceGo \
    --SecurityGroupId "$sg_id" --VSwitchId "$vsw_id" \
    --InstanceName qalos-build-20260909-150000 \
    --InternetMaxBandwidthOut 10 --InternetChargeType PayByTraffic \
    --SystemDisk.Category cloud_essd --SystemDisk.Size 500 \
    --KeyPairName "$kp_name" --Amount 1
```

JSON parse:
```json
{
  "InstanceIdSets": { "InstanceIdSet": ["i-bp1xxxxxxxxxxxx"] }
}
```

jq filter: `... | jq -r '.InstanceIdSets.InstanceIdSet[0]'`

**Gotcha — spot strategy:** Aliyun's `--SpotStrategy SpotAsPriceGo`
is set on the same `RunInstances` call as `--InstanceChargeType
PostPaid`. The CLI does not have a separate `--Spot` flag. The
default `--SpotStrategy NoSpot` is on-demand.

**Gotcha — disk size for PL2:** ESSD PL2 requires a minimum of 461
GB. 500 GB is the smallest that lands on PL2 automatically. For
PL1, 40 GB is enough; the Java compile phase runs ~20 % slower.

**Gotcha — new account risk limit:** `Forbidden.RiskControl` on
16+ GB instance types. The 2026-09-03 probe on the user's account
hit this. Fix: file a quota increase at
`https://ecs.console.aliyun.com → 配额管理 → 提交配额申请`. The
CLI response will look like:
```json
{
  "Code": "Forbidden.RiskControl",
  "Message": "You are not allowed to create the instance because of risk control.",
  "HostId": "ecs-cn-hangzhou.aliyuncs.com"
}
```

**Gotcha — new account rate limit:** the first 1-2 `RunInstances`
calls in a session may return `SDK.ServerError` for 1-2 minutes.
The retry pattern (4× with 3s backoff) handles this.

### `ecs DescribeInstances`

Wait for the instance to reach `Running` and get its public IP:

```bash
aliyun ecs DescribeInstances \
    --RegionId cn-hangzhou --InstanceIds "['i-bp1xxxxxxxxxxxx']"
```

JSON parse:
```json
{
  "Instances": {
    "Instance": [
      {
        "InstanceId": "i-bp1xxxxxxxxxxxx",
        "Status": "Running",
        "PublicIpAddress": { "IpAddress": ["8.8.8.8"] }
      }
    ]
  }
}
```

jq filter for status + IP:
```bash
... | jq -r '.Instances.Instance[0] | "\(.Status)|\(.PublicIpAddress.IpAddress[0] // empty)"'
```

The standard wait loop is in the runbook.

### `ecs StopInstance`

Stop the instance (required before `DeleteInstance`; see below).

```bash
aliyun ecs StopInstance --RegionId cn-hangzhou --InstanceId i-bp1xxxxxxxxxxxx
```

JSON parse: returns the request id; success is empty JSON `{}`.

### `ecs DeleteInstance`

Delete the instance. **Must follow `StopInstance`.**

```bash
aliyun ecs DeleteInstance \
    --RegionId cn-hangzhou --InstanceId i-bp1xxxxxxxxxxxx --Force true
```

**Gotcha — `DeleteInstance` on a `Running` instance can return
`SDK.ServerError`.** This is a known Aliyun quirk. Always
`StopInstance` first, wait for `Stopped`, then `DeleteInstance`.
The runbook implements this. (See root AGENTS.md §7.3.)

**Gotcha — `DeleteInstance` may return success while the instance
is still being torn down.** Verify with a follow-up
`DescribeInstances` call:

```bash
for i in $(seq 1 20); do
    count=$(aliyun ecs DescribeInstances --RegionId cn-hangzhou \
        --InstanceIds "['$instance_id']" | jq -r '.Instances.Instance | length')
    [[ "$count" == "0" ]] && break
    sleep 3
done
```

### `ecs CreateImage`

Create a custom image from a stopped instance.

```bash
aliyun ecs CreateImage \
    --RegionId cn-hangzhou --InstanceId i-bp1xxxxxxxxxxxx \
    --ImageName qalos-build-warm \
    --Description "qalos warm AOSP build image"
```

JSON parse:
```json
{ "ImageId": "m-bp1xxxxxxxxxxxx" }
```

### `ecs DescribeImages` (own images)

Look up an image by name:

```bash
aliyun ecs DescribeImages \
    --RegionId cn-hangzhou --ImageOwnerAlias self \
    --ImageName qalos-build-warm
```

## Error code table

| Code | Meaning | Fix |
|---|---|---|
| `Forbidden.RiskControl` | New account is risk-limited to small instance types | File a quota increase. Wait for approval. |
| `MissingParameter` | A required parameter is missing (e.g. `SecurityGroupId`) | Read the script error and add the missing param. |
| `InvalidVpcId.NotFound` | VSwitch/SG is empty or invalid | The script needs to load `$state.sgId` and `$state.vswId` correctly. |
| `InvalidImageId.NotFound` | The image ID is wrong or wrong region | Confirm the image is in the same region. |
| `ImageNotBelongToYou` | Trying to use another account's image | Use `--ImageOwnerAlias self` to find your own images. |
| `OperationDenied` | Instance type not allowed (typically t5 burstable on small accounts) | Pick the next-largest in-stock type. |
| `Throttling` / `ServiceUnavailable` / `InternalError` | Transient. | Retry with backoff (the runbook does this). |
| `SDK.ServerError` (bare, on stderr) | The aliyun CLI's useless error. | Look at stdout (JSON) for the real `Code` and `Message`. |
| `Spot.PriceTooHigh` | (Rare for `SpotAsPriceGo`.) | Retry; the market price fluctuates. |
| `QuotaExceeded` | You hit a quota on the target resource. | File a quota increase. |

## SSH / SCP from the orchestrator

The runbook uses Windows OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`).
The Aliyun ECS guest agent auto-creates the `root` user on first
boot and drops the SSH keypair's public key into
`/root/.ssh/authorized_keys`.

```bash
# From Git Bash (or any bash)
ssh -i "$HOME/.ssh/id_rsa" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@<public-ip>" 'echo ready'
```

```powershell
# From PowerShell
& 'C:\Windows\System32\OpenSSH\ssh.exe' -i "$env:USERPROFILE\.ssh\id_rsa" `
    -o StrictHostKeyChecking=no `
    "root@<public-ip>" 'echo ready'
```

For `scp`, the same flags apply. The SSH key on Aliyun is the
one whose **public** key was passed to `ImportKeyPair`; the
private key stays on the orchestrator.
