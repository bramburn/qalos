# RemoteControlService

The on-device half of QA Lab OS. A system service that runs inside
`system_server` and exposes a small HTTP/JSON API for a workstation
to drive the device for end-to-end testing.

## Layout

```
packages/apps/RemoteControlService/
├── README.md                          ← you are here
├── REBASE.md                          ← rebase runbook for the AOSP patches
├── src/com/qalos/remotectl/
│   ├── IRemoteControl.aidl            ← internal AIDL contract
│   ├── RemoteControlService.java      ← system service in system_server
│   └── HttpApiServer.java             ← embedded HTTP/JSON front-end
├── patches/
│   ├── 0001-services-core-Android-bp-srcs.patch
│   ├── 0002-AndroidManifest-REMOTE_CONTROL-permission.patch
│   ├── 0003-strings-REMOTE_CONTROL.patch
│   ├── 0004-SystemServer-StartRemoteControlService.patch
│   └── verify-patches.sh              ← `git apply --check` for all four
└── tests/
    └── README.md                      ← placeholder for future on-target tests
```

## How it builds

`tools/apply-qalos.sh` (in the qalos manifest repo) copies the
`src/com/qalos/remotectl/` directory into the AOSP working tree at
`frameworks/base/services/core/java/com/qalos/remotectl/` and
applies the four patches. The build then compiles the service into
the `services.core` java_library, which is part of `system_server`.

The build target is `qalos_emulator-userdebug` (or
`sdk_phone64_x86_64-eng` for AOSP-verified builds). See
[`website/docs/qa-lab-os/build-guide.md`](../../../website/docs/qa-lab-os/build-guide.md)
for the full procedure.

## API

See [`website/docs/qa-lab-os/api.md`](../../../website/docs/qa-lab-os/api.md).
The HTTP server binds to `127.0.0.1:9000` by default; reach it from
the host via `adb forward tcp:9000 tcp:9000`.

## License

Java/AIDL files: Apache-2.0 (matches the AOSP convention for
framework-side code). Shell scripts: MIT (matches the rest of qalos).
Each file carries an SPDX header.

## Versioning

This is **v0**. See
[`website/docs/qa-lab-os/plan.md`](../../../website/docs/qa-lab-os/plan.md)
for what is in scope and what is deferred.
