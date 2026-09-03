<!--
Thanks for the PR! Please fill in every section below. PRs with empty
sections will be closed and asked to be re-opened with the missing info.

Need help? See CONTRIBUTING.md.
-->

## What

<!-- One-sentence summary of the change. -->

## Why

<!-- The problem this solves. Link an issue with `Fixes #123` if there is one. -->

## How

<!-- The approach. If this touches the architecture (AGENTS.md), link to the section
     it implements or extends. -->

## Test plan

<!-- What you ran locally to validate. Examples:
     - "I ran `tools/aliyun-smoke-test.ps1` and it passed (instance launched, deleted)."
     - "I ran `shellcheck scripts/aliyun-*.sh` and it reported 0 issues."
     - "I ran `markdownlint '**/*.md'` and it reported 0 issues."
     For AOSP-touching changes that don't need a full build:
     - "I ran `tools/do-build.sh --dry-run` and it stopped at the right place."
-->

## Risk / rollback

<!-- For risky changes: how to revert. For trivial changes: "Trivial, revert the commit." -->

## Checklist

- [ ] I have read [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] I have read [AGENTS.md](../AGENTS.md) and my change does not violate the architecture rules (or I have documented the exception below)
- [ ] I have updated the relevant docs in `website/docs/` (if my change is user-facing)
- [ ] I have updated AGENTS.md (if my change touches the architecture, the safety nets, the warm-image pattern, or the cost rules)
- [ ] I have kept the PowerShell and shell versions in sync (for tooling changes)
- [ ] I have run the local CI checks (PSScriptAnalyzer / shellcheck / markdownlint / gitleaks) and they pass
- [ ] I have run the smoke test for any new build path

### Architecture exception (if applicable)

<!-- If your change violates a rule in AGENTS.md, document the exception here.
     Explain what rule, why, and what trade-off is accepted. -->
