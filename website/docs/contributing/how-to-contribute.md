---
sidebar_position: 2
---

# How to contribute

The canonical source is [`CONTRIBUTING.md`](https://github.com/bramburn/qalos/blob/main/CONTRIBUTING.md) in the repo root. This page is a navigable summary.

## Ground rules

1. **All PRs require an approval before they can merge.** This is enforced by GitHub branch protection. See [`BRANCH_PROTECTION.md`](https://github.com/bramburn/qalos/blob/main/BRANCH_PROTECTION.md) for the exact rules.
2. **CI runs static checks only.** AOSP builds are NOT run on GitHub Actions — they take 2-6 hours and would burn the free tier in a single build. The CI workflow validates scripts, markdown, secrets, and links. See [CI checks](ci-checks).
3. **The architecture and design rules in [AGENTS.md](https://github.com/bramburn/qalos/blob/main/AGENTS.md) are non-negotiable** unless a PR explicitly documents the exception in its description. If a change violates one of the rules, the PR should explain why and what trade-off it accepts.

## Filing issues

Use the issue templates at [`.github/ISSUE_TEMPLATE/`](https://github.com/bramburn/qalos/tree/main/.github/ISSUE_TEMPLATE):

- **Bug report** — for AOSP build failures, script crashes, CI failures.
- **Feature request** — for new build paths, new tools, or new AOSP integrations.
- **Question** — use [GitHub Discussions](https://github.com/bramburn/qalos/discussions), not issues, for "how do I..." questions.

## Filing PRs

1. Fork the repo and create a topic branch off `main`.
2. Make your change. Keep commits small and atomic. Imperative-mood commit messages: `add aliyun smoke test`.
3. Update relevant docs:
   - **New tool / script**: add to the [tools reference](../reference/tools-reference) and the [architecture overview](../architecture/overview) if it introduces a new concept.
   - **AGENTS.md change**: PRs that touch the architecture, the safety nets, or the warm-image pattern MUST update AGENTS.md in the same PR.
   - **Bug fix**: add a `### Known limitations` note to the affected page if the fix is partial.
4. Run the local CI checks before pushing (see [CI checks](ci-checks)).
5. Push and open a PR against `main`. Fill in the [PR template](https://github.com/bramburn/qalos/blob/main/.github/PULL_REQUEST_TEMPLATE.md) completely.
6. Address review feedback with new commits (don't squash mid-review). The maintainer will squash-merge once approved.

## Code style

### PowerShell (`tools/*.ps1`)

- 4-space indent.
- PascalCase functions, camelCase variables.
- `$ErrorActionPreference = 'Stop'` + `$PSNativeCommandUseErrorActionPreference = $true` at the top.
- Every orchestrator script MUST implement the four safety nets.

### Shell (`tools/*.sh`, `scripts/*.sh`)

- 2-space indent.
- `set -euo pipefail` at the top.
- Use `[[ ... ]]`, not `[ ... ]`. Quote your variables.
- Every orchestrator script MUST mirror the safety nets: `trap`, a watchdog process, and (if it launches a remote instance) an on-host watchdog.

### Markdown

- ATX-style headings (`# Heading`, not Setext).
- Wrap at 100 columns.
- Fenced code blocks with a language tag.
- One sentence per line in prose paragraphs (easier diffs).

## What's next

- Want to know what CI checks your PR against? → [CI checks](ci-checks)
- Want the design rules your PR must respect? → [Architecture overview](../architecture/overview)
