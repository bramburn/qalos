---
sidebar_position: 1
---

# Architecture

The opinionated, end-to-end design rules for qalos. These are non-negotiable unless a PR explicitly documents the exception in its description.

If you only read one page in this section, read [Overview](overview).

## Pages

- [Overview](overview) — the three build paths, the single source of truth, the design rules
- [Safety nets](safety-nets) — the four layers that prevent orphaned cloud resources
- [Warm-image pattern](warm-image-pattern) — why we never reinstall build dependencies on every run

## The canonical source

This section is the human-facing mirror of [`AGENTS.md`](https://github.com/bramburn/qalos/blob/main/AGENTS.md) in the repo root. `AGENTS.md` is the **canonical source of truth** for any agent (or human) picking up the repo — it's what AI agents read first. This docs site is a navigable, prettier version for humans browsing on the web.

If the two ever disagree, `AGENTS.md` wins. PRs that change architecture should update both.
