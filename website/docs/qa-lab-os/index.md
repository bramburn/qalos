---
id: index
title: QA Lab OS overview
sidebar_label: Overview
sidebar_position: 1
description: A custom AOSP-based system image with a native HTTP API for remote device control.
---

# QA Lab OS

QA Lab OS is a custom Android system image that turns a phone (or
emulator) into a **dumb execution endpoint** for end-to-end testing. A
workstation connects to it over a small HTTP/JSON API and can:

- tap, long-press, swipe, pinch, drag
- type text and inject hardware keys
- launch or force-stop apps
- take a screenshot of any display
- query the foreground package, display size, and device health

The phone is intentionally simple. **All decisions live on the
workstation** — typically a vision-capable LLM that sees the screenshot
and emits the next `x, y` coordinate to tap.

## Why

We want to run true multi-app E2E tests against a production app that
interacts with 2-3 other apps, without leaking the automation layer
into the apps' detection surface. Stock-Android + Appium is the
common path, but it requires constant cloaking work (root hiding,
Appium-package hiding, accessibility-service removal). QA Lab OS
**is** the OS — input injection and screenshot capture happen in
framework code, so there are no extra packages for the apps to see.

## How it fits into qalos

qalos is an AOSP fork manifest (pinned to `android-15.0.0_r1`) with a
thin qalos-specific overlay (a product makefile, one first-party app).
QA Lab OS lives in the overlay:

```
qalos/
├── packages/apps/RemoteControlService/   # the privileged system APK
├── tools/qa-lab-os/                      # the Python client + mock
├── device/qalos/qalos_emulator/          # device.mk adds the APK
└── website/docs/qa-lab-os/               # this Docusaurus site
```

## Two phases

- **Phase 1 (v0, this branch)** — the API works on the AOSP emulator.
  Build with `lunch sdk_phone64_x86_64-eng` and verify on a local AVD.
- **Phase 2 (follow-up)** — port the same APK to a physical Pixel 7
  image, add kernel-level root hiding (KernelSU-Next + SuSFS) for
  apps that detect modification.

## Status

- [x] PRD agreed
- [x] Plan drafted
- [ ] Design questions answered
- [ ] Source code written
- [ ] Multi-pass AI static review
- [ ] AVD-verified on Linux box
- [ ] PR opened

See [`v0 plan`](./plan) for the step-by-step and the open questions.
