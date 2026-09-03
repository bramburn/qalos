---
sidebar_position: 2
---

# Folder structure

The canonical layout of the qalos repo. The Docusaurus site lives in `website/`, the Windows orchestrators in `tools/`, and the macOS/Linux orchestrators in `scripts/`.

```
.
├── AGENTS.md                              # canonical, machine-readable architecture doc
├── README.md                              # public-facing quickstart
├── CONTRIBUTING.md                        # PR workflow, branch protection, code style
├── CODE_OF_CONDUCT.md                     # Contributor Covenant 2.1
├── BRANCH_PROTECTION.md                   # exact gh api command to apply branch protection
├── LICENSE                                # MIT for qalos + Apache 2.0 attribution for AOSP
├── default.xml                            # the AOSP manifest; pins android-15.0.0_r1
├── upstream.xml                           # verbatim copy of AOSP's default.xml at that tag
├── .gitignore
├── .editorconfig                          # 4-space PS, 2-space sh/bash/md/yaml, 4-space Java
├── .markdownlint.jsonc                    # markdown lint config (ATX, 100-col, fenced code)
│
├── .github/                               # GitHub-side config
│   ├── CODEOWNERS                         # review-request routing
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md
│   │   └── feature_request.md
│   └── workflows/
│       ├── build.yml                      # existing: DO build on push/main + manual
│       ├── ci.yml                         # NEW: static checks (no AOSP)
│       └── deploy-docs.yml                # NEW: Docusaurus -> GitHub Pages
│
├── device/qalos/qalos_emulator/           # qalos product makefile (branding, build id)
├── packages/apps/QaLab/                   # the only first-party qalos app
│   ├── src/
│   ├── Android.mk
│   └── AndroidManifest.xml
│
├── tools/                                 # WINDOWS ORCHESTRATORS (.ps1) + ON-HOST (.sh)
│   ├── apply-qalos.sh                     # on-host: copy qalos content to AOSP working tree
│   ├── setup-droplet.sh                   # on-host: install AOSP build deps (used by setup-base)
│   ├── do-build.sh                        # on-host: the AOSP build (single source of truth)
│   ├── doctl-install.ps1                  # Windows: install doctl
│   ├── doctl-setup-base.ps1               # Windows: create DO base droplet + warm snapshot
│   ├── doctl-build.ps1                    # Windows: on-demand DO build
│   ├── doctl-avd.ps1                      # Windows: on-demand AVD launch
│   ├── aliyun-install.ps1                 # Windows: install aliyun CLI
│   ├── aliyun-smoke-test.ps1              # Windows: smoke test + bootstrap VPC/SG/keypair
│   ├── aliyun-setup-base.ps1              # Windows: create Aliyun base ECS + warm custom image
│   └── aliyun-build.ps1                   # Windows: on-demand Aliyun build
│
├── scripts/                               # macOS / LINUX ORCHESTRATORS (.sh)
│   ├── aliyun-install.sh                  # macOS/Linux: install aliyun CLI
│   ├── aliyun-smoke-test.sh               # macOS/Linux: smoke test + bootstrap
│   ├── aliyun-setup-base.sh               # macOS/Linux: create warm custom image
│   ├── aliyun-build.sh                    # macOS/Linux: on-demand Aliyun build
│   └── lib/                               # shared shell helpers
│       ├── aliyun-common.sh               #   - retry / JSON parse / state helpers
│       └── log.sh                         #   - color logging
│
├── website/                               # Docusaurus site (deployed to GitHub Pages)
│   ├── package.json
│   ├── docusaurus.config.js
│   ├── sidebars.js
│   ├── babel.config.js
│   ├── README.md                          # (Docusaurus convention, for the npm package page)
│   ├── docs/                              # the human-facing mirror of AGENTS.md
│   │   ├── intro.md
│   │   ├── getting-started/
│   │   ├── architecture/
│   │   ├── reference/
│   │   └── contributing/
│   ├── src/
│   │   ├── pages/index.js                 # the home page
│   │   ├── pages/index.module.css
│   │   └── css/custom.css
│   └── static/
│       ├── .nojekyll                      # tells GitHub Pages to skip Jekyll
│       └── img/
│           ├── logo.svg
│           └── favicon.svg
│
├── docs/                                  # LEGACY: pre-Docusaurus docs. Kept for the old README links.
│   ├── README.md                          # redirects to website/
│   ├── agent-brief.md                     # superseded by AGENTS.md + website/docs/architecture/
│   ├── local-build.md                     # superseded by website/docs/getting-started/local-build.md
│   ├── setup.md                           # superseded by website/docs/getting-started/do-build.md
│   └── gcp-cost-analysis/                 # KEEP: separate project (icelabz-portal), unrelated to qalos
│       └── icelabz-portal-cost-analysis.py
│
└── .pi/                                   # ephemeral state (gitignored)
    └── aliyun-state.json                  # written by aliyun-smoke-test.{ps1,sh}, read by the other aliyun-* scripts
```

## The "single source of truth" rule

For each kind of file, there is **one** canonical place:

| File type | Canonical location | Mirrored at |
| --- | --- | --- |
| AOSP build steps | `tools/do-build.sh` | (none — only this) |
| Architecture / design rules | `AGENTS.md` (repo root) | `website/docs/architecture/*` (human-facing) |
| Public quickstart | `README.md` (repo root) | `https://bramburn.github.io/qalos/` (website home) |
| Brand assets (logo, favicon) | `website/static/img/` | (none — only this) |
| Aliyun infra state | `.pi/aliyun-state.json` | (none — gitignored on purpose) |
| Windows orchestrators | `tools/aliyun-*.ps1` | `scripts/aliyun-*.sh` (macOS/Linux twin) |

When two files cover the same thing (e.g., a Windows `.ps1` and a Linux `.sh`), they are **deliberate twins**, not "single source of truth with a wrapper". Logic that should be in only one place lives in the on-host script (`tools/do-build.sh`), which is already a shell script and runs on Linux/macOS by default.

## Where to put a new file

| I want to add... | Put it in... |
| --- | --- |
| A new AOSP build step | `tools/do-build.sh` (no twin needed) |
| A new Windows orchestrator | `tools/<name>.ps1` AND `scripts/<name>.sh` (keep in sync) |
| A new macOS/Linux orchestrator | `scripts/<name>.sh` AND `tools/<name>.ps1` (keep in sync) |
| A new AOSP product file | `device/qalos/qalos_emulator/` or `packages/apps/QaLab/` |
| A new doc page | `website/docs/<section>/<page>.md` AND update `sidebars.js` |
| A new CI check | `.github/workflows/ci.yml` (add a new job) |
| A new OSS file | repo root, named per convention (`SECURITY.md`, `SUPPORT.md`, etc.) |

## What's next

- Want to look up a specific script? → [Tools reference](tools-reference)
- Want to know the gotchas? → [Gotchas](gotchas)
