---
id: plan
title: v0 plan
sidebar_label: v0 plan
sidebar_position: 2
description: What we are building, in what order, and why.
---

# QA Lab OS — v0 plan

> **Status: draft.** This plan is the first concrete shape of the project.
> It will be updated as the user answers the design questions in the review thread.

## What is "QA Lab OS"?

A custom-built Android system image (qalos-flavored) that exposes a small
HTTP API on the device so a workstation can drive the phone — tap, type,
swipe, screenshot, launch, force stop — for end-to-end testing of
multi-app flows.

The phone is a **dumb execution endpoint**. The agent (LLM + Python) on
the workstation is the **brain**. The two communicate over a plain
HTTP/JSON API on `localhost:9000`, tunneled out via `adb forward` for
emulator or ADB-over-USB / ADB-over-Wi-Fi for physical devices.

## v0 scope (this branch)

`feat/qa-lab-os-v0` ships:

| Layer | Deliverable |
| --- | --- |
| System service | Privileged system APK at `packages/apps/RemoteControlService/` (Java + AIDL) |
| Build integration | `device/qalos/qalos_emulator/device.mk` adds `RemoteControlService` to the product |
| Client SDK | Python package at `tools/qa-lab-os/client.py` |
| Mock server | Pure-Python mock of the on-device HTTP API for CI / local dev |
| Tests | `pytest` suite that exercises the client against the mock server |
| Docs | This Docusaurus site: architecture, API, build guide, agent dev guide, static-check workflow |
| Static checks | AI (this agent) performs 4 review passes and captures findings inline |

**v0 does NOT include**: Phase-2 kernel hiding, GPS spoofing, Play
Integrity bypass, multi-device orchestration, the Python LLM agent loop
template. Those are explicit follow-ups.

## Build vs framework — the fork question

The PRD sketches two shapes. **For v0 we picked option 1, the heavy
path**, despite the larger maintenance cost — the user wants the
"true native" service in `system_server` and accepts the rebase
burden.

1. **Framework service in `system_server`** (chosen) — the Java
   package is `com.qalos.remotectl`. Source lives in the qalos overlay
   and is copied to the AOSP tree by `tools/apply-qalos.sh`. Four
   upstream AOSP files are modified by small, focused patches.
2. **Privileged system app** — the "middle ground" the PRD itself names
   as ~90% of the power at ~10% of the maintenance. Single APK signed
   with the platform key, living in `/system/priv-app/`. Not used in v0.

The full rationale is in
[`decisions.md`](./decisions#d-002--v0-shape-framework-service-in-system_server).
The rebase runbook is in
[`build-guide.md`](./build-guide#rebase-runbook).

## Where the build happens

qalos builds on a Linux box (Ubuntu 22.04+, 32 GB+ RAM, 300 GB+ disk).
The AOSP source tree is ~200 GB once `repo sync` finishes; the first
`m` for `sdk_phone64_x86_64-eng` is 30-60 minutes; incremental rebuilds
of `frameworks/base` are 2-5 minutes.

The v0 PR will not be build-verified by the agent in this environment
(see host constraints below). The Python client + mock server + tests
are run on the agent's host. The AOSP build + on-emulator verification
happens on the user's Linux box following the build guide.

## Static checks — the 4-pass review

The user requested AI static review with multiple passes. v0 will
produce a `review/` folder with one markdown file per pass:

1. **Code review** — style, naming, AOSP conventions, AIDL correctness,
   Java threading rules, HTTP server hardening.
2. **Security review** — auth boundary, input validation, info disclosure
   on error paths, screenshot handling, Python client trust model.
3. **Architecture review** — separation of concerns, testability,
   dependency direction, build-system footprint, error-handling
   consistency.
4. **Docs review** — does the code match the docs? Are the API examples
   actually executable? Does the build guide work on a clean checkout?

Each pass produces a `review/PASS-N-*.md` file with a numbered list of
findings, each tagged `must-fix` / `should-fix` / `nit`. The code is then
updated and the review file is amended in place so the diff between
"as found" and "as fixed" is visible.

## Open questions for the user

The blocking questions were answered in the kickoff chat. Summary, with
the answers recorded in
[`decisions.md`](./decisions):

| # | Question | Answer |
| --- | --- | --- |
| 1 | Build approach | **Framework service in `system_server`** (D-002) |
| 2 | Build host | Local Linux box (per qalos AGENTS.md "local first"). Aliyun reserved for Phase 2. |
| 3 | Test scope | Source + mock + pytest on the agent host; AVD smoke on the user's Linux box. |
| 4 | v0 API surface | **Minimal subset** — see D-005a |
| 5 | Static-check tooling | AI 4-pass review in `qa-lab-os/review/`; no new CI tooling in v0. |
| 6 | Documentation placement | New `qa-lab-os/` Docusaurus section. |
| 7 | License | Apache 2.0 for Java/AIDL, MIT for Python/docs. |
| 8 | Review format | Inline fixes + a written report per pass. |
| 9 | Package + class naming | **`com.qalos.remotectl`** (D-002a). |

## Constraints carried in from the qalos repo

- The AOSP fork manifest pins `android-15.0.0_r1`. v0 builds on that.
- Local Linux is the primary build path. DigitalOcean and Aliyun are
  fallbacks.
- All on-demand cloud build scripts must implement the four safety
  nets (trap/finally + background watchdog + on-host watchdog +
  workflow cleanup). This applies to any future AVD-on-cloud work in
  this project.
- The CI workflow runs static checks only — no AOSP builds on GH
  Actions.

## What you can do right now to help

- **Answer the 9 questions** in the chat. They are the only blocking
  decisions.
- **Confirm the branch name** `feat/qa-lab-os-v0` is acceptable.
- **Confirm the package name** `com.qalos.remotectl` is acceptable
  (alternatives: `com.qalab.remotectl`, `com.bramburn.remotectl`).
- **Decide whether v0 should also include a build-script** that wires
  the new APK into the AOSP tree, or whether that's a follow-up.
