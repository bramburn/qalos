# SSH access to local Ubuntu LAN hosts

> Reference for any agent (human or LLM) reaching the project's local
> Ubuntu boxes from a Windows dev machine. No secrets are reproduced
> here — only key file paths and connection commands.

## Hosts

| IP | Hostname hint | Key in `~/.ssh/` | Verified | Notes |
|---|---|---|---|---|
| `192.168.0.44` | (LAN box A) | `timetracker_deploy_new` | unverified this session | legacy entry in `~/.ssh/config` |
| `192.168.0.45` | (LAN box B / "the Linux box") | `id_ed25519_qalos` | yes (this session) | the AOSP sync gateway, see `AGENTS.md` §5.5 |
| `192.168.0.46` | (LAN box C) | `id_ed25519_qalos` (assumed) | not yet | no `~/.ssh/config` entry yet |
| `192.168.0.132` | (LAN box D) | `timetracker_deploy_new` | unverified this session | legacy entry in `~/.ssh/config` |

User on every box: `bramburn`.

## Connect from Windows cmd.exe

```cmd
ssh -i "%USERPROFILE%\.ssh\id_ed25519_qalos" bramburn@192.168.0.45
```

Quote the `-i` path — cmd treats backslashes as path separators and breaks on unquoted paths.

## Connect from PowerShell

```powershell
ssh -i "$env:USERPROFILE\.ssh\id_ed25519_qalos" bramburn@192.168.0.45
```

## Connect from Git Bash / WSL

```bash
ssh -i ~/.ssh/id_ed25519_qalos bramburn@192.168.0.45
```

## Recommended `~/.ssh/config` (Windows-side)

Replace the legacy `.45` block and add `.46`:

```sshconfig
Host 192.168.0.45
  HostName 192.168.0.45
  User bramburn
  IdentityFile ~/.ssh/id_ed25519_qalos

Host 192.168.0.46
  HostName 192.168.0.46
  User bramburn
  IdentityFile ~/.ssh/id_ed25519_qalos
```

After this is in place, `ssh 192.168.0.45` and `ssh 192.168.0.46` Just Work — no flags.

(The other LAN entries in `~/.ssh/config` — `.44`, `.132` — keep using
`timetracker_deploy_new` for now; only change them after confirming
that key is also installed on those hosts.)

## Windows PATH gotcha — `'ssh' is not recognized`

On a fresh Windows install, `C:\Windows\System32\OpenSSH\` (where the
Windows OpenSSH client `ssh.exe` lives) is **not** in the user's
`PATH`. Symptom in cmd / PowerShell:

```
'ssh' is not recognized as an internal or external command,
operable program or batch file.
```

Git Bash has its own `ssh.exe` at
`C:\Program Files\Git\usr\bin\ssh.exe`, so the command appears to
"work" inside Git Bash while failing in plain cmd — confusing when
reading docs.

**One-time fix** (user-level PATH, no admin needed). Run in
PowerShell:

```powershell
[Environment]::SetEnvironmentVariable(
  "Path",
  [Environment]::GetEnvironmentVariable("Path","User") + ";C:\Windows\System32\OpenSSH",
  "User"
)
```

Open a **new** cmd / PowerShell window — already-open windows do not
pick up the change. Verify:

```cmd
where ssh
ssh -V
```

Expected: `C:\Windows\System32\OpenSSH\ssh.exe` and
`OpenSSH_for_Windows_<version>`.

## Pitfalls

- **`/tmp` in Git Bash is not a real Windows path.** Files written
  there via bash are invisible to PowerShell / cmd. Use `$env:TEMP`
  or `C:\Users\<user>\AppData\Local\Temp\` for cross-shell scripts.
- **OneDrive key paths are decoy.** The legacy snippet
  `C:\Users\bramburn\OneDrive\Documents\Keys\id_rsa` does not exist;
  the real keys live in `C:\Users\bramburn\.ssh\`. Do not paste
  OneDrive-path key references into scripts.
- **"Connection timed out" vs "Connection refused".** Timed out =
  firewall / silently dropped (host off-LAN or blocking port 22).
  Refused = host up but `sshd` not listening (check
  `systemctl status sshd` on the box).
- **`~/.ssh/config` matches the *first* `Host` block.** If two blocks
  have overlapping IPs (e.g. `192.168.0.132` and `192.168.0.1322`),
  put the more specific one first — `ssh_config` does not prefer
  exact-match unless it's earlier in the file.

## See also

- [`AGENTS.md` §5.5](../AGENTS.md#55-two-hop-aosp-sync-via-linux-box-aliyun-workaround) —
  how `192.168.0.45` is used as the open-internet gateway for the
  Aliyun two-hop sync.
- `~/.ssh/config` — live configuration.
