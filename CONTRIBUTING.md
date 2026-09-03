# Contributing to qalos

Thanks for your interest in qalos. This document covers the **practical mechanics** of contributing: what to file, how to file it, the PR workflow, the code style, and the CI checks. For the **architecture and design rules** that govern every script in `tools/`, see [AGENTS.md](AGENTS.md).

## Ground rules

- **All PRs require an approval before they can merge.** This is enforced by GitHub branch protection. See [BRANCH_PROTECTION.md](BRANCH_PROTECTION.md) for the exact rules.
- **CI runs static checks only.** AOSP builds are NOT run on GitHub Actions — they take 2-6 hours and would burn the free tier in a single build. The CI workflow validates scripts, markdown, secrets, and links. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
- **The architecture and design rules in [AGENTS.md](AGENTS.md) are non-negotiable** unless a PR explicitly documents the exception in its description. If a change violates one of the rules, the PR should explain why and what trade-off it accepts.

## Filing issues

Use the issue templates in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/):

- **Bug report** — for AOSP build failures, script crashes, CI failures.
- **Feature request** — for new build paths, new tools, or new AOSP integrations.
- **Question** — use [GitHub Discussions](https://github.com/bramburn/qalos/discussions), not issues, for "how do I..." questions.

For security issues, **do not file a public issue** — see [SECURITY.md](SECURITY.md) (to be added when there's something worth reporting).

## Filing PRs

1. Fork the repo and create a topic branch off `main`:
   ```bash
   git checkout main
   git pull
   git checkout -b feat/short-descriptive-name
   ```
2. Make your change. Keep commits small and atomic. Write commit messages in the imperative mood: `add aliyun smoke test`, not `added` or `adds`.
3. Update relevant docs:
   - **New tool / script**: add to the [tools reference](website/docs/reference/tools-reference.md) and the [architecture overview](website/docs/architecture/overview.md) if it introduces a new concept.
   - **AGENTS.md change**: PRs that touch the architecture, the safety nets, or the warm-image pattern MUST update AGENTS.md in the same PR.
   - **Bug fix**: add a `### Known limitations` note to the affected page if the fix is partial.
4. Run the local CI checks before pushing:
   ```bash
   # PowerShell scripts
   Invoke-ScriptAnalyzer -Path tools/ -Settings PSGallery

   # Shell scripts
   shellcheck scripts/**/*.sh

   # Markdown
   markdownlint '**/*.md' --config .markdownlint.jsonc

   # Secrets
   gitleaks detect --source . --no-banner
   ```
5. Push and open a PR against `main`. Fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md) completely — incomplete PRs will be closed.
6. Address review feedback with new commits (don't squash mid-review). The maintainer will squash-merge once approved.

### What goes in a PR description

- **What** — one-sentence summary.
- **Why** — the problem this solves (link an issue if there is one).
- **How** — the approach; if it touches the architecture, link to the AGENTS.md section it implements or extends.
- **Test plan** — what you ran locally. "I ran `tools/aliyun-smoke-test.ps1` and it passed" is fine.
- **Risk / rollback** — for risky changes, how to revert.

## Code style

### PowerShell (`tools/*.ps1`)

- 4-space indent, no tabs.
- PascalCase for functions, camelCase for variables.
- `Set-StrictMode -Version Latest` at the top of every script.
- Always `$ErrorActionPreference = 'Stop'` and `$PSNativeCommandUseErrorActionPreference = $true` when calling native CLIs.
- Every orchestrator script MUST implement the four safety nets from [AGENTS.md §5.3](AGENTS.md). PRs that add a new build script without the safety nets will be rejected.

### Shell (`tools/*.sh`, `scripts/*.sh`)

- 2-space indent, no tabs.
- `set -euo pipefail` at the top of every script.
- Use `[[ ... ]]` for tests, not `[ ... ]`. Quote your variables.
- Every orchestrator script MUST mirror the safety nets: a `trap` for cleanup, a watchdog process, and (if it launches a remote instance) an on-host watchdog.

### Markdown

- ATX-style headings (`# Heading`, not Setext).
- Wrap at 100 columns.
- Fenced code blocks with a language tag: ` ```bash `, not just ` ``` `.
- One sentence per line in prose paragraphs (easier diffs).
- Run `markdownlint` before pushing.

### QaLab app (Java/Kotlin under `packages/apps/QaLab/`)

- Follow the [AOSP Java Code Style](https://source.android.com/setup/contribute/code-style).
- 4-space indent, 100-column line limit, braces on the same line.

## Repo conventions

- **Folder structure** is documented in [website/docs/reference/folder-structure.md](website/docs/reference/folder-structure.md). If your change adds a new top-level folder, update that doc in the same PR.
- **Tooling changes** (anything in `tools/` or `scripts/`) MUST keep the PowerShell and shell versions in sync. If you change one, change the other. If you can't, file an issue describing the gap.
- **Docusaurus content** lives in `website/docs/`. To preview the docs site locally:
  ```bash
  cd website
  npm install
  npm run start
  ```
  The site is at http://localhost:3000.

## What CI checks

| Check | Tool | Scope | Blocking? |
| --- | --- | --- | --- |
| PowerShell syntax + style | PSScriptAnalyzer | `tools/*.ps1` | yes |
| Shell syntax + style | shellcheck | `tools/*.sh`, `scripts/*.sh` | yes |
| Markdown lint | markdownlint | `**/*.md` | yes |
| Secret scan | gitleaks | whole repo | yes |
| JSON / XML schema | `jq` + custom | `default.xml`, `upstream.xml` | yes |
| Broken links | lychee | `**/*.md` | yes |
| AOSP build | (not run) | — | no |

If a CI check fails on your PR, the failure message will tell you which tool flagged which line. Run the same tool locally to reproduce, fix, and re-push.

## Release process

There is no formal release process yet. Builds are produced by:
- Local Linux box (the primary path)
- DO droplet or Aliyun ECS (fallback, see [AGENTS.md §4.2 and §4.3](AGENTS.md))

When a new build succeeds, the maintainer pushes the resulting images to a `release/<version>` branch and tags it. Consumers pin to that tag in their `default.xml` revision.

## Code of conduct

By participating, you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).
