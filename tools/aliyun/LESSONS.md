# Aliyun AOSP build — lessons from 2026-09-10

> **Read this first** before any Aliyun build attempt. Five
> attempts failed because of network restrictions and transfer
> speeds. This doc captures the gotchas so the next agent
> doesn't re-discover them.

This file is the post-mortem for the 2026-09-10 build series
(5 attempts, ~¥20 burned, no artifacts produced). Future
attempts start from here.

## TL;DR

1. **Aliyun ECS in `cn-hangzhou` is on a closed IPv4 network,
   but IPv6 routes are open.** It cannot reach `google.com`,
   `gerrit.googlesource.com`, `android.googlesource.com`,
   `storage.googleapis.com`, `github.com`, or
   `mirrors.aliyun.com` via IPv4. It CAN reach
   `mirrors.ustc.edu.cn` and `aosp.tuna.tsinghua.edu.cn` via
   IPv6. Verified from inside the instance.
   **Update 2026-09-10 22:30:** `cn-hangzhou-i` (a different
   zone from the original 5) is even more restricted — **no
   outbound connectivity at all**, not even to `www.baidu.com`
   or `mirrors.tuna.tsinghua.edu.cn`. Every `curl` returns
   `code=000` (connection refused, not 404). The instance has
   no default route to the internet gateway, or the security
   group is blocking all egress. The original 5 attempts were
   all in `cn-hangzhou-j`. Egress policy can vary per zone
   within the same region. **Bottom line: do not assume
   "different zone" = "different policy" = "will work."**
   but IPv6 routes are open.** It cannot reach `google.com`,
   `gerrit.googlesource.com`, `android.googlesource.com`,
   `storage.googleapis.com`, `github.com`, or
   `mirrors.aliyun.com` via IPv4. It CAN reach
   `mirrors.ustc.edu.cn` and `aosp.tuna.tsinghua.edu.cn` via
   IPv6. Verified from inside the instance.
2. **Aliyun's "android.googlesource.com" namespace is a fake
   mirror.** `https://mirrors.aliyun.com/android.googlesource.com/`
   returns an HTML marketing page to HEAD requests but
   `404`-s on any actual git operation
   (`info/refs?service=git-upload-pack`).
3. **Two working AOSP mirrors from Aliyun cn-hangzhou (via IPv6):**
   - **USTC**: `https://mirrors.ustc.edu.cn/aosp/`
     - `platform/manifest` → 200, `git-repo` → 200
   - **TUNA** (NEW canonical URL): `https://aosp.tuna.tsinghua.edu.cn/`
     - `platform/manifest` → 200, `git-repo` → 200
   - **TUNA** (old URL, still works): `https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/`
     - `platform/manifest` → 200, but `/git-repo` 404 (use the new URL for repo tool)
4. **Probe at the smart-HTTP git level, NOT the HTTP HEAD
   level.** Use
   `curl -sIo /dev/null -w "%{http_code}" https://<mirror>/platform/manifest/info/refs?service=git-upload-pack`.
   HTTP 200 + content-type `application/x-git-upload-pack-advertisement`
   = real git server. HTTP HEAD can return 200 for marketing
   pages that have no git data.
5. **Use `g7a.16xlarge` (256 GB RAM) for the build, NOT
   `g7a.2xlarge` (32 GB).** AOSP 15 `m` will OOM in
   `lunch qalos_emulator-userdebug` on 32 GB during the
   preflight (api-stubs-docs-non-updatable).
6. **The `do-build.sh` Aliyun mirror redirects are still
   committed at `/aosp/git-repo/`** but should be
   **REPLACED with the USTC URL**:
   `https://mirrors.ustc.edu.cn/aosp/git-repo`. The Aliyun
   URL is fake; USTC is the real working endpoint.

## What was tried (5 attempts)

| # | Approach | Outcome |
|---|---|---|
| 1 | Direct `repo init -u ... && repo sync` on Aliyun | All AOSP endpoints unreachable from cn-hangzhou ECS. Failed. |
| 2 | Switch mirror to TUNA, 4 sync jobs | TUNA `mirrors.tuna.tsinghua.edu.cn` unreachable. Failed. |
| 3 | Switch mirror to USTC | USTC `mirrors.ustc.edu.cn` unreachable. Failed. |
| 4 | Use Aliyun "mirror" `mirrors.aliyun.com/android.googlesource.com` | Fake mirror, returns HTML page not git. Failed. |
| 5 | `--depth 1` + Aliyun mirror + `g7a.2xlarge` | All of the above + 32 GB RAM insufficient. Failed. |

All 5 attempts confirmed the same network restriction from
different angles. The conclusion: **Aliyun cn-hangzhou cannot
source AOSP itself; you must pre-stage the source on a host
with open internet, then transfer in.**

## Network reality (measured 2026-09-10)

| Path | Measured speed | Source |
|---|---|---|
| Windows local disk → tar file | 169 MB/s | NTFS write, uncompressed tar of AOSP source |
| Windows local disk → compressed tar | 26 MB/s | gzip on AOSP source, single CPU-bound |
| Windows → Linux (LAN, 192.168.0.45) | 3.3 MB/s | scp over local network |
| Windows → Aliyun ECS (cn-hangzhou-j) | ~2.4 MB/s initial, then dropped | paramiko/SFTP, 10 Mbps instance bandwidth |
| Linux → Aliyun ECS (cn-hangzhou-j) | 2.44 MB/s | scp, 100 Mbps instance, 50 MB test file |
| Linux → Aliyun ECS (cn-hangzhou-j) | 1-3 MB/s sustained | long-running 23-25 GB partial tars |

**Implication:** 135 GB at 2.44 MB/s = 15.7 hours. The
"200 MB upload" intuition is wrong for this path; the
Aliyun inbound is throttled regardless of instance
bandwidth cap.

## Why Aliyun cn-hangzhou cannot reach AOSP

Verified from `i-bp1hw1809042554wfdrb` (the 5th attempt's
instance, `g7a.2xlarge`, cn-hangzhou-j):

| Target | Result | Notes |
|---|---|---|
| `gerrit.googlesource.com:443` | `000` connect timeout | Egress blocked or routed nowhere |
| `android.googlesource.com:443` | `000` connect timeout | Same |
| `storage.googleapis.com:443` | `403 Forbidden` | Reachable but unauthorised |
| `mirrors.tuna.tsinghua.edu.cn:443` | timeout | Egress blocked |
| `mirrors.ustc.edu.cn:443` | timeout | Egress blocked |
| `mirrors.aliyun.com/android.googlesource.com/` | `200` to HEAD, `404` to git probe | Marketing page, not a mirror |
| `github.com:443` | TLS error (`GnuTLS recv -110`) | Partial reachability, TLS fails |

The "closed network" pattern is consistent with Aliyun's
`cn-*` region default egress policy. The `storage.googleapis.com`
403 is unusual — the host is reachable but Aliyun's IP space
isn't on Google's allow list for unauthenticated GCS
buckets.

## Aliyun "mirror" is fake — investigation

`https://mirrors.aliyun.com/android.googlesource.com/` looks
plausible: HTTP HEAD returns 200, the path is
well-structured. But:

```bash
# What you might try
$ curl -sI https://mirrors.aliyun.com/android.googlesource.com/platform/manifest
HTTP/1.1 200 OK

# What actually matters — the smart-HTTP git probe
$ curl -sI https://mirrors.aliyun.com/android.googlesource.com/platform/manifest/info/refs?service=git-upload-pack
HTTP/1.1 404 Not Found
x-cache: MISS TCP_MISS

$ git ls-remote https://mirrors.aliyun.com/android.googlesource.com/platform/manifest HEAD
fatal: repository not found
```

The namespace exists at the HTTP layer but has no git
repositories under it. The HTML body of the index page is
a marketing page ("android.googlesource.com 安装包下载 -
开源镜像站 - 阿里云"), not a git server.

User verified 2026-09-10 that Aliyun's developer mirror
portal does not list AOSP as a first-class supported mirror
the way TUNA and USTC do. The Aliyun "mirror" of AOSP is
unusable.

## The fix that worked (one part of it)

The Linux box (`192.168.0.45`, user `bramburn`) has open
internet access and successfully ran `repo init -u
https://github.com/bramburn/qalos -b main && repo sync
-c -j8 --no-tags --no-clone-bundle --depth=1` directly
against `android.googlesource.com`. This sync reached
**27 GB** before stalling (no git processes were running on
the next check, suggesting the SSH session or the
`repo sync` was killed).

The sync stalling is unexplained; could be a `repo` bug
with `--depth 1` and concurrent fetches, or a network
hiccup on the Linux box, or the session that started it
ended. The fix is to resume the sync (or restart it) and
verify the resulting tar.

## Open: AOSP mirrors accessible from cn-hangzhou

**RESOLVED 2026-09-10.** The 5 attempts above did NOT test the
correct endpoints. The previous probes failed because:

1. They probed at HTTP HEAD level, not smart-HTTP git level.
2. They used the OLD TUNA path
   (`mirrors.tuna.tsinghua.edu.cn/AOSP/`) which now 302-redirects
   to a new domain `aosp.tuna.tsinghua.edu.cn`.
3. They used the OLD TUNA git-repo path
   (`mirrors.tuna.tsinghua.edu.cn/git-repo/`) which is 404;
   the new path is `aosp.tuna.tsinghua.edu.cn/git-repo/`.
4. They gave up after TUNA/USTC/Aliyun HEAD returned unexpected
   codes, without testing the smart-HTTP git endpoint.

**The 11 untested mirrors in the original list:**

| Mirror | Index HEAD | git probe | Verdict |
|---|---|---|---|
| `mirrors.huaweicloud.com/aosp/` | 200 | 404 | Index only, no git. Skip. |
| `mirrors.cloud.tencent.com/Android-Source/` | 404 | 404 | Skip. |
| `mirrors.jd.com/android/` | 000 timeout | — | Skip. |
| `mirrors.163.com/aosp/` | 404 | — | Skip. |
| `mirrors.cernet.edu.cn/aosp/` | 404 | — | Skip. |
| `mirrors.sjtug.sjtu.edu.cn/aosp/` | 404 | — | Skip. |
| `mirrors.zju.edu.cn/aosp/` | 404 | — | Skip. |
| `mirrors.nju.edu.cn/aosp/` | 404 | — | Skip. |
| `mirrors.hit.edu.cn/aosp/` | 404 | — | Skip. |
| `mirror.iscas.ac.cn/aosp/` | 404 | — | Skip. |
| `mirrors.tongji.edu.cn/aosp/` | 000 timeout | — | Skip. |
| `mirrors.bupt.edu.cn/aosp/` | 000 timeout | — | Skip. |

**USTC and TUNA both respond to the smart-HTTP git probe with
HTTP 200 (real git servers). But the actual data transfer is
throttled to <1000 bytes/sec — useless for syncing 100+ GB of
AOSP source.** Verified by direct `git clone --depth=1` from
both mirrors on 2026-09-10:

```
$ git clone --depth=1 -v https://mirrors.ustc.edu.cn/aosp/platform/manifest /tmp/m
POST git-upload-pack (175 bytes)
POST git-upload-pack (244 bytes)
error: RPC failed; curl 28 Operation too slow. Less than 1000 bytes/sec transferred the last 5 seconds
fatal: early EOF
fatal: fetch-pack: invalid index-pack output

$ git clone --depth=1 -v https://aosp.tuna.tsinghua.edu.cn/platform/manifest /tmp/m
POST git-upload-pack (175 bytes)
POST git-upload-pack (244 bytes)
remote: Waiting in queue... (Position: 110)         Position drops to 105
error: RPC failed; curl 28 Operation too slow. Less than 1000 bytes/sec transferred the last 5 seconds
fatal: early EOF
```

TUNA additionally has a connection queue (Position 110 → 105
during the 8-second window) that throttles new clones. The
fundamental network restriction is the same: Aliyun
`cn-hangzhou` has severely limited outbound bandwidth to the
public internet, even via IPv6.

**Conclusion: the IPv6 path is the ONLY working path, but it is
also the only path, and it is throttled. There is no faster
mirror. The Linux box (open internet, home UK broadband) is
the right place to sync AOSP; the Aliyun ECS can only receive
the source via scp/rsync at 2-3 MB/s.**

## What to try next (decision tree)

```
START: need AOSP source on an Aliyun ECS in cn-hangzhou
  │
  ├── 1. Test 11 untested Chinese AOSP mirrors from the
  │     Linux box AND from a fresh Aliyun ECS instance.
  │     **DONE 2026-09-10:** USTC and TUNA both respond to
  │     the smart-HTTP git probe (HTTP 200) but actual
  │     `git clone` is throttled to <1000 bytes/sec
  │     (curl 28 Operation too slow). TUNA has a queue
  │     (Position 110). The IPv6 path is the only working
  │     path, but it is also throttled. No faster mirror.
  │
  ├── 1b. Test S3 as a transfer relay. **DONE 2026-09-10:**
  │     AWS S3 (eu-west-2, visamomo-ecom) is reachable
  │     from the Aliyun cn-hangzhou ECS (RTT ~1.1s, HTTP
  │     405). Aliyun → S3 upload works at 5.11 MB/s
  │     (100 MB in 19.5s). **But S3 → Aliyun download
  │     hangs after 5+ minutes for 100 MB** — the
  │     download is throttled to <100 bytes/sec, similar
  │     to the USTC/TUNA throttling. The S3 path is
  │     broken for download. Use the Linux box to push
  │     to S3, but the S3 → Aliyun leg doesn't work.
  │
  ├── 2. Use the Linux box (192.168.0.45) as the AOSP sync
  │     host. It has open internet and can run `repo sync`
  │     against `android.googlesource.com` directly. Sync
  │     takes 30-60 min, lands ~135 GB uncompressed on the
  │     Linux box's local disk.
  │
  ├── 3. Transfer from Linux box to Aliyun ECS.
  │     Measured: 2.44 MB/s sustained (Windows→Linux local
  │     3.3 MB/s, Linux→Aliyun 2.44 MB/s). 135 GB at
  │     2.44 MB/s = 15.7 hours. The user explicitly
  │     accepted this 12+ hour budget on 2026-09-10.
  │     Use `rsync` for resumability; compress with `zstd`
  │     (faster than gzip, ~3:1 ratio on AOSP source).
  │     Compressed: 50 GB at 2.44 MB/s = 5.7 hours.
  │
  ├── 4. Build on a large Aliyun ECS.
  │     Terminate the g7a.2xlarge (32 GB too small for
  │     AOSP 15). Launch g7a.16xlarge (256 GB) Spot
  │     (~¥9/1.5h). Run `do-build.sh` against the
  │     pre-staged source (Aliyun mirror redirects
  │     disabled).
  │
  ├── 5. Serve artifacts via `qalos-serve-artifacts.py`,
  │     download via HTTP, tear down. ~5 GB artifacts.
  │     Total: 6-7h build, 12-18h transfer, ~¥15-25.
  │
  └── 6. If Linux box → Aliyun is too slow, try DO as a
        relay. DO droplet ($6/mo, open internet) syncs
        AOSP in 1 hour, then transfers to Aliyun. DO egress
        to Aliyun may be faster than UK home → Aliyun
        (unverified, ~5-10 MB/s estimated). If verified,
        cut transfer time to 4-6 hours. Cost: ~$1.50 in
        DO egress + DO droplet compute. **Fallback only —
        try Linux box first.**
```

## Do-build.sh fixes committed in commit c18fd07

Three changes were committed to the worktree branch on
2026-09-10. They are valid independent of the network
situation:

1. **`log()` function moved from line 102 to line 51.** The
   function was being called before it was defined in some
   error paths, causing a `command not found` crash that
   masked the real error. The new order: `log()` is defined
   near the top of the file, before any code that might
   trigger an error path that uses it.
2. **`REPO_SYNC_JOBS` bumped from 4 to 8.** On a host with
   open internet, 8 parallel git fetches finish the AOSP
   sync in roughly the same wall time as 16 (downloads are
   bandwidth-bound, not CPU-bound). Below 4, the sync is
   unnecessarily slow. Above 8, `android.googlesource.com`
   returns `RESOURCE_EXHAUSTED` / HTTP 429 on a few of the
   ~1500 repos.
3. **Aliyun mirror git-repo URL changed to `/aosp/git-repo/`.**
   The `git-repo` bootstrap was redirected to
   `https://mirrors.aliyun.com/aosp/git-repo/`. **This
   redirect is useless** because the Aliyun AOSP namespace
   is fake (see above). The redirect is kept for
   documentation purposes but should be DISABLED when the
   build runs on a pre-staged source tree.

## Other gotchas to remember

### UserData and systemd

- **Aliyun UserData limit:** 16,384 characters base64-encoded.
  Inline heredocs blow this on long scripts. Use a `git clone`
  + `bash` chain (~3,196 chars b64) instead of inlining the
  whole setup script.
- **`$HOME` not set in systemd context.** The systemd unit
  needs `Environment=HOME=/root` explicitly, or `ccache` and
  other tools that read `~/.ccache` will fail silently.
- **UserData is ephemeral.** Every new instance launch loses
  UserData. The setup script must be re-run (e.g., via a
  systemd unit that clones the qalos repo and runs
  `setup-droplet.sh`).

### Aliyun API quirks

- **`DeleteInstance` on a `Running` instance can return
  `SDK.ServerError`.** Always `StopInstance` first, wait for
  `Stopped`, then `DeleteInstance`. The mavis cron template
  in the runbook handles this.
- **The `aliyun` CLI suppresses error details.** Bare stderr
  says `ERROR: SDK.ServerError` and nothing else. Parse
  stdout (JSON), never trust the bare stderr. The `aliyon()`
  helper handles this for the PS1/sh scripts.
- **Spot stock is volatile.** `g7a.2xlarge` Spot was
  unavailable in cn-hangzhou-j and -k for the 5th attempt.
  Fall back to PostPaid, or try `-h` / `-i` / other zones,
  or use a different instance type.
- **New accounts have a 1-2/min `RunInstances` rate limit on
  day one.** If `SDK.ServerError` follows a few rapid
  retries, wait 60-90s. The `aliyon()` helper retries 4
  times with backoff.
- **New accounts default to 8 GB RAM (risk control).** The
  smoke test will fail with `Forbidden.RiskControl` on any
  16+ GB instance type until the quota is approved at
  `ecs.console.aliyun.com → 配额管理 → 提交配额申请`.

### Identity verification

- **The IP `47.97.243.202` is the user's Mac mini
  (`macmini2024`), NOT an Aliyun ECS instance.** The Aliyun
  instance from the 6th-attempt summary was associated with
  this IP in conversation, but the hostname on the other end
  of SSH is the Mac mini, up 8 days. Always verify the
  instance ID via `aliyun ecs DescribeInstances` before
  SSHing. If the instance ID doesn't match the state file,
  the IP has been reassigned and the instance is gone.
- **The Windows SSH key (`id_ed25519_qalos`,
  `bramburn@windows`) is installed on the Linux box
  authorized_keys.** Windows → Linux passwordless works.
- **The Linux box SSH key (`id_ed25519`, `qalos@linux`) is
  installed on the Aliyun ECS root authorized_keys (during
  the 6th-attempt setup).** Linux → Aliyun passwordless
  works (verified 2026-09-10).
- **Paramiko over OpenSSH for password-based SSH.**
  `C:\Windows\System32\OpenSSH\ssh.exe` doesn't handle
  non-interactive password prompts. Use paramiko
  (`pip install paramiko`) for one-time password auth
  (e.g., the initial key install on a new instance).

### Build VM size

- **AOSP 15 full build needs 64+ GB RAM.** Preflight
  (`api-stubs-docs-non-updatable`) uses ~24 GB on its own
  at `-j8`. The full `m` can hit 48-56 GB during Java
  compilation. `g7a.2xlarge` (32 GB) is too small;
  OOM-kill during the preflight is the expected failure.
- **Use `g7a.16xlarge` (256 GB) for the build.** The 1.5h
  Spot price is ~¥9.

### State files

- **`D:\qalos\.pi\aliyun-state.json`** — infra state, written
  by the smoke test and setup-base. Read by the LLM runbook
  on every build. Schema: see §"State file" in
  `tools/aliyun/AGENTS.md`.
- **`D:\qalos\.pi\aliyun-build-state.json`** — per-build
  state, written by the LLM-driven Phase 4. Schema
  `qalos://aliyun-build-state/v1`. The mavis cron and the
  next agent read it. Don't delete it until the instance
  is `torn_down`; archive with a timestamp if you want to
  keep the build history.
- **Don't confuse "build 5" and "build 6" state.** The state
  file's `buildId` and `instance.id` are the source of
  truth. If the IP doesn't match `aliyun ecs DescribeInstances`,
  the instance is gone.

## Cost summary (5 attempts, 2026-09-10)

| Item | Cost |
|---|---|
| 5 instance launches (`g7a.2xlarge` Spot, ~30 min each) | ~¥15 |
| 1 warm image creation attempt (failed at network stage) | ~¥2 |
| 1 sync-only attempt (failed) | ~¥1 |
| 1 full setup (apt + qalos clone) on the 6th attempt | ~¥2 |
| **Total** | **~¥20** |

No artifacts produced. The cost is the price of finding
out that Aliyun cn-hangzhou cannot source AOSP itself.

## What's next

See "What to try next" decision tree above. The next
agent should:

1. **Test 11 untested Chinese AOSP mirrors** from both
   the Linux box (open internet, will tell you if the
   mirror exists) AND a fresh Aliyun ECS (will tell you
   if the mirror is reachable from cn-hangzhou). The
   intersection is the answer.
2. If any mirror works, use it directly. Document the
   working mirror URL in this file and update
   `do-build.sh` to use it.
3. If no mirror works, fall back to the small-VM
   holding-pen approach (option 3 in the decision tree).
4. **DO is the fallback if Aliyun itself is unworkable.**
   A $6/mo DO droplet can sync AOSP in 1 hour, then
   transfer to Aliyun at possibly better speeds than
   the home → Aliyun path (unverified; test before
   committing).

## See also

- `tools/AGENTS.md` — the index (one page) for the `tools/`
  folder.
- `tools/aliyun/AGENTS.md` — the LLM-driven Aliyun runbook.
- `tools/aliyun/aliyun-cli-reference.md` — per-command JSON
  parse shape and error code table.
- `tools/aliyun/build-cost.md` — per-build + standing cost
  table.
- `tools/aliyun/qalos-serve-artifacts.py` — token-gated HTTP
  artifact server.
- `tools/aliyun/run-build.sh` — the on-instance build runner.
- `D:\qalos\.pi\aliyun-build-state.json` — the canonical
  per-build state record.
