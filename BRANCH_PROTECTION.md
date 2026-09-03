# Branch protection for `main`

This repo enforces the policy: **no PR can be merged into `main` without at least one approved review.** This is a GitHub-side setting; the actual rules live in the repo's branch protection configuration, not in the code.

This file documents the exact rules and the commands to apply or update them.

## The rules

`main` is protected with the following:

| Setting | Value |
| --- | --- |
| Require a pull request before merging | **yes** |
| Require approvals | **1** |
| Dismiss stale pull request approvals when new commits are pushed | **yes** |
| Require review from Code Owners | **yes** (see [`.github/CODEOWNERS`](.github/CODEOWNERS)) |
| Require linear history | **yes** (no merge commits) |
| Require status checks to pass before merging | **yes** (see workflow list below) |
| Require branches to be up to date before merging | **yes** |
| Require conversation resolution before merging | **yes** |
| Block force pushes | **yes** |
| Allow deletions | **no** |
| Allow force pushes to the matching branch | **no** |
| Allow force pushes to admins | **no** |
| Require signed commits | **no** (overridden — too much friction for a small project) |
| Include administrators | **yes** (the rules apply to admins too) |

### Required status checks

The following CI checks must pass before a PR can merge:

- `CI / lint-powershell` (PSScriptAnalyzer)
- `CI / lint-shell` (shellcheck)
- `CI / lint-markdown` (markdownlint)
- `CI / secret-scan` (gitleaks)
- `CI / link-check` (lychee)
- `CI / validate-manifest` (JSON + XML schema for `default.xml` / `upstream.xml`)

These are defined in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## How to apply (one-time, by a repo admin)

You need the GitHub CLI (`gh`) authenticated as a user with admin access to the repo.

```bash
# Verify auth
gh auth status

# Apply the ruleset to main
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  /repos/bramburn/qalos/branches/main/protection \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "CI / lint-powershell",
      "CI / lint-shell",
      "CI / lint-markdown",
      "CI / secret-scan",
      "CI / link-check",
      "CI / validate-manifest"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
```

If the `JSON` heredoc is awkward in your shell, save it to a file and pass it as `--input branch-protection.json`.

## How to verify

```bash
gh api /repos/bramburn/qalos/branches/main/protection | jq .
```

You should see `enforce_admins: true`, `required_pull_request_reviews.required_approving_review_count: 1`, and the six required status checks.

## How to update

If you need to add a new required status check (e.g., for a new CI job):

1. Add the job to `.github/workflows/ci.yml` and push it to a branch.
2. Wait for it to run on a PR and see the exact status check name (it appears in the PR's checks list).
3. Update the JSON in the command above to include the new check name.
4. Re-run the `gh api PUT` command.

## What's not in the rules (and why)

- **No required signed commits.** Too much friction for a small project. If your threat model includes compromised contributor accounts, add `require_signed_commits: true` to the JSON.
- **No restrictions on who can push.** The `restrictions` field is `null`, meaning anyone with write access can push to non-protected branches. If you want to limit to a maintainers team, set `restrictions: { "users": [], "teams": ["maintainers"] }` after creating the team.
- **No CODEOWNERS enforcement on the `default.xml` / `upstream.xml` changes** — those files are mostly AOSP manifest content, not authored by us. The Code Owners are defined for our actual authored files (see [`.github/CODEOWNERS`](.github/CODEOWNERS)).
