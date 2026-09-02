# qalos — first-time setup

Five things to do once. After that, builds are one command.

## 1. Create a DigitalOcean account

https://cloud.digitalocean.com/signup — credit card or PayPal, no minimum.

## 2. Generate a DO API token

https://cloud.digitalocean.com/account/api/tokens/new

- Name: `qalos`
- Scopes: **Read** + **Write**
- Copy the token (it's only shown once).

Set it in this PowerShell session and persist it for future sessions:

```powershell
[Environment]::SetEnvironmentVariable('DO_API_TOKEN', '<paste-token>', 'User')
$env:DO_API_TOKEN = '<paste-token>'
```

## 3. Create a Spaces bucket and access keys

https://cloud.digitalocean.com/spaces — create a bucket (region: **lon1** to match the default build region, name e.g. `qalos-builds`).

Then https://cloud.digitalocean.com/account/api/spaces — generate a Spaces access key. Save the **access key** and **secret key**.

Set the four Spaces env vars:

```powershell
$vars = @{
    'QALOS_SPACES_BUCKET' = 'qalos-builds'
    'QALOS_SPACES_REGION' = 'lon1'
    'QALOS_SPACES_KEY'    = '<spaces-access-key>'
    'QALOS_SPACES_SECRET' = '<spaces-secret-key>'
}
foreach ($k in $vars.Keys) {
    [Environment]::SetEnvironmentVariable($k, $vars[$k], 'User')
    Set-Item -Path "Env:\$k" -Value $vars[$k]
}
```

## 4. Register an SSH key with DigitalOcean

If you don't already have a DO-registered SSH key:

```powershell
# Generate a key if you don't have one
if (-not (Test-Path ~/.ssh/id_ed25519)) {
    ssh-keygen -t ed25519 -C 'qalos@icelabz' -f ~/.ssh/id_ed25519 -N '""'
}
# Upload to DO
doctl compute ssh-key import qalos --public-key-file ~/.ssh/id_ed25519.pub
```

## 5. Push this repo to GitHub and create the GH Actions secrets

The build on-demand flow works without GitHub, but GH Actions is the cleanest trigger.

```powershell
cd D:\qalos
git init
git add .
git commit -m "qalos: initial fork scaffold"
git branch -M main
git remote add origin git@github.com:bramburn/qalos.git
git push -u origin main
```

Then at https://github.com/bramburn/qalos/settings/secrets/actions add:

| Secret name             | Value                           |
| ----------------------- | ------------------------------- |
| `DO_API_TOKEN`          | your DO API token               |
| `QALOS_SPACES_BUCKET`   | `qalos-builds`                  |
| `QALOS_SPACES_REGION`   | `lon1`                          |
| `QALOS_SPACES_KEY`      | Spaces access key               |
| `QALOS_SPACES_SECRET`   | Spaces secret key               |

## 6. Install `doctl` on this Windows box

```powershell
cd D:\qalos
.\tools\doctl-install.ps1
```

## 7. One-time: create the base snapshot

This spins up a fresh c-8 droplet, runs `setup-droplet.sh` (installs all AOSP build deps), and snapshots it as `qalos-build-warm`. Takes ~10 min and costs ~$0.03.

```powershell
.\tools\doctl-setup-base.ps1
```

After it finishes, **destroy the base droplet manually in the DO control panel** if it wasn't cleaned up automatically (it should be, but DO sometimes delays the destroy).

## You're set up

Trigger a build:

```powershell
.\tools\doctl-build.ps1
```

Or push to `main` on GitHub, or click "Run workflow" in the Actions tab.

## Upgrading later

If a build OOMs on c-8 (8 vCPU / 16 GB), retry with c-16:

```powershell
.\tools\doctl-build.ps1 -DropletSize c-16
```

Or via GH Actions: Run workflow → Droplet size = c-16.
