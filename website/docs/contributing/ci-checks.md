---
sidebar_position: 3
---

# CI checks

The qalos CI workflow runs **static checks only**. AOSP builds are NOT run on GitHub Actions — they take 2-6 hours and would burn the free tier in a single build. The CI workflow validates scripts, markdown, secrets, and links.

The full workflow is in [`.github/workflows/ci.yml`](https://github.com/bramburn/qalos/blob/main/.github/workflows/ci.yml).

## What CI checks

| Check | Tool | Scope | Blocking? | Local command |
| --- | --- | --- | --- | --- |
| PowerShell syntax + style | PSScriptAnalyzer | `tools/*.ps1` | yes | `Invoke-ScriptAnalyzer -Path tools/ -Settings PSGallery` |
| Shell syntax + style | shellcheck | `tools/*.sh`, `scripts/*.sh` | yes | `shellcheck tools/*.sh scripts/**/*.sh` |
| Markdown lint | markdownlint | `**/*.md`, `**/*.mdx` | yes | `markdownlint '**/*.md' --config .markdownlint.jsonc` |
| Secret scan | gitleaks | whole repo | yes | `gitleaks detect --source . --no-banner` |
| JSON / XML schema | `jq` + custom | `default.xml`, `upstream.xml` | yes | `python -c "import json,xml.etree.ElementTree as ET; ..."` |
| Broken links | lychee | `**/*.md` | yes | `lychee --offline '**/*.md'` |
| AOSP build | (not run) | — | no | (n/a — build locally or on cloud fallback) |

If a CI check fails on your PR, the failure message will tell you which tool flagged which line. Run the same tool locally to reproduce, fix, and re-push.

## The six required status checks (for branch protection)

The branch protection rule (see [BRANCH_PROTECTION.md](https://github.com/bramburn/qalos/blob/main/BRANCH_PROTECTION.md)) requires these six status checks to pass before a PR can merge:

- `CI / lint-powershell`
- `CI / lint-shell`
- `CI / lint-markdown`
- `CI / secret-scan`
- `CI / link-check`
- `CI / validate-manifest`

The exact status-check names are taken from the `name:` field of each job in the workflow file. If you add a new CI job, update BRANCH_PROTECTION.md with the new name and re-apply the ruleset.

## Running the checks locally

### PowerShell (PSScriptAnalyzer)

```powershell
# Install once
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force

# Run on all PowerShell scripts
Invoke-ScriptAnalyzer -Path tools/ -Settings PSGallery
```

### Shell (shellcheck)

```bash
# macOS
brew install shellcheck
# Ubuntu
sudo apt-get install -y shellcheck
# Windows
scoop install shellcheck
# or download from https://github.com/koalaman/shellcheck/releases

# Run
shellcheck tools/*.sh
shellcheck scripts/**/*.sh
```

### Markdown (markdownlint)

```bash
# npm
npm install -g markdownlint-cli

# Run
markdownlint '**/*.md' --config .markdownlint.jsonc
```

### Secrets (gitleaks)

```bash
# macOS
brew install gitleaks
# Linux: download from https://github.com/gitleaks/gitleaks/releases
# Windows
scoop install gitleaks

# Run
gitleaks detect --source . --no-banner
```

### Link check (lychee)

```bash
# install via cargo
cargo install lychee

# Run offline (no network, just checks internal links + known external patterns)
lychee --offline '**/*.md'
```

## Adding a new check

1. Add a new job to `.github/workflows/ci.yml`. Use a stable `name:` (it becomes the status-check name in branch protection).
2. Add the same check to the local-CI section in [CONTRIBUTING.md](https://github.com/bramburn/qalos/blob/main/CONTRIBUTING.md) and this page.
3. If the check should be **required** for merge, update `BRANCH_PROTECTION.md` with the new status check name and re-apply the ruleset via `gh api`.

## What's next

- Want to file a PR? → [How to contribute](how-to-contribute)
- Want to know the design rules your PR must respect? → [Architecture overview](../architecture/overview)
