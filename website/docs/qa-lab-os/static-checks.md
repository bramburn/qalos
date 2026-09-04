---
id: static-checks
title: Static check workflow
sidebar_label: Static checks
sidebar_position: 8
description: How the AI 4-pass review works, who runs it, and where the findings live.
---

# Static check workflow

QA Lab OS is reviewed by AI in **four passes**, each producing a
written report that lives in the repo and is amended in place as
findings are fixed.

## The four passes

| # | Pass | Scope | Output file |
| --- | --- | --- | --- |
| 1 | **Code review** | Java/AIDL style, AOSP conventions, threading, HTTP server hardening, Python PEP-8, type hints | `qa-lab-os/review/PASS-1-code.md` |
| 2 | **Security review** | Auth boundary, input validation, info disclosure on error paths, screenshot handling, Python client trust, `localhost`-binding correctness | `qa-lab-os/review/PASS-2-security.md` |
| 3 | **Architecture review** | Separation of concerns, testability, dependency direction, build-system footprint, error-handling consistency, API ergonomics | `qa-lab-os/review/PASS-3-architecture.md` |
| 4 | **Docs review** | Does the code match the docs? Are the API examples executable on the mock server? Does the build guide work on a clean checkout? | `qa-lab-os/review/PASS-4-docs.md` |

## Finding tags

Every finding is tagged one of:

- **`must-fix`** — blocks the v0 PR. Bug, security flaw, doc lies.
- **`should-fix`** — included before merge. Style, ergonomics, missing
  test.
- **`nit`** — included if cheap. Naming, comment wording, ordering.

## The cycle

```
   ┌────────────────────────────────────────────────┐
   │  write code                                    │
   │       │                                        │
   │       ▼                                        │
   │  run pass N  ─────►  PASS-N-*.md produced     │
   │       │                                        │
   │       ▼                                        │
   │  for each finding:                             │
   │     fix in code                                │
   │     mark finding as FIXED in PASS-N-*.md       │
   │       │                                        │
   │       ▼                                        │
   │  re-run pass N  ────►  any new findings?       │
   │       │                                        │
   │       ▼                                        │
   │  if clean, advance to pass N+1                 │
   └────────────────────────────────────────────────┘
```

## Severity gates

- A `must-fix` finding blocks advancing to the next pass.
- A `should-fix` finding blocks merge.
- `nit` findings are optional and may be deferred with a `[DEFERRED]`
  note in the report.

## When the cycle is "done"

The v0 PR is reviewable when:

1. All four `PASS-N-*.md` files exist.
2. Every `must-fix` and `should-fix` finding is marked `FIXED` (or
   `WONTFIX` with a one-line reason and an issue link).
3. Each pass was re-run after the last fix in that pass and produced
   no new findings.

## What the AI looks for

### Pass 1 — code

- **AOSP Java conventions** — naming (`m` prefix for members, `s` for
  static), `@hide` on internal APIs, `final` on injected dependencies,
  no public no-arg constructors on services.
- **AIDL** — oneway where appropriate, primitives for hot path, package
  declarations correct, no over-broad types.
- **Threading** — `system_server` is single-threaded for most services;
  long operations on a worker; `HandlerThread` for the HTTP server.
- **HTTP server** — bound port in `try/finally`; per-connection thread
  with a timeout; bounded request body; consistent error JSON.
- **Python** — type hints on all public functions, `requests` timeout
  default, no global state, docstring on every public class.
- **Tests** — every endpoint has a happy-path test; at least one error
  test; the mock server is deterministic.

### Pass 2 — security

- **Auth boundary** — the `127.0.0.1` bind is the v0 boundary. Any code
  path that bypasses it is `must-fix`.
- **Input validation** — every JSON field is bounds-checked (integers
  in `[0, display_size]`, strings length-capped, no shell metacharacters
  in any exec path).
- **Error disclosure** — error messages must not leak class names,
  file paths, or stack traces to the client.
- **Screenshot handling** — base64-encoded; not logged; not cached to
  disk unless the client asks.
- **Python client** — never `eval` or `exec` server JSON; the
  `X-API-Key` (when added in Phase 2) is read from env, not hard-coded.
- **Logging** — no `Log.d` of input coordinates, package names, or
  screenshot bytes in release builds.

### Pass 3 — architecture

- **Service layer** — `RemoteControlService` is the only entry point;
  `HttpApiServer` is the only network code; `IRemoteControl` is the
  only IPC contract.
- **Build footprint** — the new package adds at most one new
  `PRODUCT_PACKAGES` entry and at most one new `device.mk` line. No
  patches to upstream AOSP files in v0.
- **Testability** — every Java method on the AIDL interface is testable
  in isolation (no static state, no hidden dependencies). The mock
  server matches the real server's response shape exactly.
- **API ergonomics** — `/health` exists, every error is a JSON
  `{"status":"error","message":...}` with an HTTP status code, every
  coordinate endpoint takes a `display` parameter (default 0).

### Pass 4 — docs

- **Truth** — every example in the docs was actually run against the
  mock server in this PR's CI run.
- **Coverage** — every endpoint in the Java service has a section in
  the API docs.
- **Build guide** — works on a clean Linux box with no manual
  intervention. A reviewer with no qalos context can follow it.
- **Agent developer guide** — explains the coordinate system, the
  action JSON shape, the recommended LLM system prompt, the latency
  budget, and the common pitfalls.
- **Decisions log** — every non-obvious choice is recorded with
  rationale.

## Tooling (what runs in CI)

The `.github/workflows/ci.yml` already runs six checks: PSScriptAnalyzer,
shellcheck, markdownlint, gitleaks, lychee, manifest validation. v0 does
**not** add Java/Python lint to CI in this branch — the AI review is
the static check, by design. A follow-up branch will wire up
checkstyle, ruff, and pytest so the human reviewer can re-run the same
checks without the agent.

## See also

- [`v0 plan`](./plan) — what is being built
- [`decisions log`](./decisions) — opinionated choices
- [`review log`](./review-log) — the actual review reports, in order
