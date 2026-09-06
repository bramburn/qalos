---
sidebar_position: 6
---

# Audit Logging Specification

> **DRAFT — not legal advice.**
> This document is a draft for review by a solicitor qualified in England & Wales before reliance,
> AND for review by a security engineer before being treated as a technical specification.
> See [README.md](index) for the framework context.

**Effective date:** 2026-09-03

## 1. Purpose

This document specifies the **audit log** that any commercial operator of a qalos device (or fleet) must maintain.
It is incorporated by reference into the [TERMS_OF_SERVICE.md](terms-of-service) and the [KYC.md](kyc).

The audit log serves four purposes:

- **Deterrence.** A customer who knows that every action is logged is less likely to attempt a prohibited use.
- **Detection.** A reviewer (internal compliance, the project owner, or a regulator) can reconstruct what the device did, when, and at whose request.
- **Investigation.** On a regulator or law-enforcement request, the audit log is the primary record of the operator's compliance with the [ACCEPTABLE_USE_POLICY.md](acceptable-use-policy).
- **Defence.** For the operator, a complete audit log is the evidence that the operator acted within the AUP if a regulator later asks.

The audit log is **not** a substitute for legal advice, and the project owner does not warrant that the audit log is sufficient for any particular regulator's standard.
It is the minimum standard that the project owner requires.

## 2. Who must keep an audit log

You must keep an audit log if any of the following applies to your use of the project:

- (a) You operate a fleet of **more than one (1)** device running a Prebuilt Image, for any purpose.
- (b) You operate any single device for **commercial use** (as defined in the ToS), other than personal hobby use.
- (c) You resell, redistribute, or provide hosted access to a Prebuilt Image or Derivative.
- (d) You have completed the KYC process in [KYC.md](kyc).
- (e) You use the `RemoteControlService` (or any successor / equivalent API) to drive the device, regardless of the number of devices.

If none of the above applies, the audit log is **recommended** but not required.

## 3. What must be logged

For every privileged action taken on or by a device running a Prebuilt Image, the audit log must capture at least the following fields.

### 3.1 Common fields (every event)

| Field | Type | Description |
| --- | --- | --- |
| `event_id` | UUID v4 | Globally unique identifier for the event. |
| `event_time` | RFC 3339 UTC timestamp with millisecond precision. | When the event was generated. |
| `device_id` | string | A stable, unique identifier for the device (the IMEI is not appropriate; use the `ro.serialno`, a generated UUID stored in `/data`, or a similar opaque value). |
| `operator_id` | string | The identity of the person or service that requested the action. For a remote API call, this is the authenticated client; for an on-device user, this is the Android user id. |
| `customer_id` | string | Your identifier for the customer on whose behalf the action was taken. If you are the customer, this is your own identifier. |
| `session_id` | UUID v4 | A session identifier that groups related events. |
| `action` | enum | The action performed (see section 3.2). |
| `target` | object | The target of the action (see section 3.3). |
| `result` | enum | `success`, `failure`, or `denied` (denied by policy, e.g. allow-list, rate limit, kill switch). |
| `reason` | string (nullable) | On `failure` or `denied`, the reason. |
| `request_ip` | string (nullable) | For remote API calls, the source IP. |
| `request_user_agent` | string (nullable) | For remote API calls, the User-Agent header. |
| `request_id` | string (nullable) | An upstream correlation id, if the operator has one. |
| `prev_event_hash` | hex (64 chars) | Hash of the previous event in this device's log (see section 5.3). |

### 3.2 The action list (minimum)

The following actions **must** be logged.
The list is the minimum; operators are encouraged to log more.

**Device lifecycle**

- `device.boot`
- `device.shutdown`
- `device.firmware_update`
- `device.config_change`
- `device.kill_switch_engaged` (the kill switch was tripped; see section 6)

**Application lifecycle (driven by `RemoteControlService` or equivalent)**

- `app.launch`
- `app.force_stop`
- `app.install`
- `app.uninstall`
- `app.permission_grant`
- `app.permission_revoke`

**Input injection (driven by `RemoteControlService` or equivalent)**

- `input.tap`
- `input.swipe`
- `input.key`
- `input.text`
- `input.long_press`
- `input.pinch`
- `input.inject_event` (any other injection)

**Output capture**

- `screen.screenshot`
- `screen.video_start`
- `screen.video_stop`
- `screen.record_audio_start` (if the device is configured to record audio)
- `screen.record_audio_stop`

**System services**

- `system.clipboard_read`
- `system.clipboard_write`
- `system.notification_post`
- `system.accessibility_take_action` (if the device is configured to use accessibility automation)

**Authentication and access**

- `auth.api_token_issue`
- `auth.api_token_revoke`
- `auth.login_success`
- `auth.login_failure`
- `auth.logout`

**Policy and audit**

- `policy.config_change` (a config that affects the audit log itself was changed)
- `policy.kill_switch_change` (the kill switch was reconfigured)
- `audit.log_export` (an export of the audit log was performed)
- `audit.log_purge` (anything was deleted from the audit log; expected to be rare and itself a red flag)

### 3.3 The target

The `target` object depends on the action:

- For an app action: `{ "package": "com.example.app", "activity": "com.example.app.MainActivity" }`.
- For an input action: `{ "x": 123, "y": 456, "duration_ms": 100, "key": "KEY_HOME" }`.
- For a screenshot: `{ "resolution": "1080x2400", "size_bytes": 412345 }`.
- For a config change: `{ "key": "audit_log_retention_days", "old": "30", "new": "365" }`.

## 4. Storage, retention, and integrity

### 4.1 Where the log lives

The audit log must be:

- (a) **Stored on the device in tamper-resistant storage** (append-only, hash-chained — see section 5.3) for at least **90 days** of rolling local retention, OR
- (b) **Streamed to a remote log sink** in real time (within 60 seconds of the event) where it is stored under your control, in tamper-resistant storage, for the retention period in section 4.2.

A combination of (a) and (b) is preferred: stream remotely for durability, retain locally for forensics if the network is down.

### 4.2 Retention

Minimum retention periods:

- **Default:** 12 months from the event.
- **Financial-regulated use** (any use that interacts with payment services, banking, investment, insurance, or anti-money-laundering controls): 7 years.
- **Government, law-enforcement, or critical-infrastructure use:** as required by the applicable regulator, and at least 7 years.

If the operator cannot determine which retention period applies, use the longest of the above.

### 4.3 Integrity (hash chain)

Each event is chained to the previous event by `prev_event_hash = SHA-256(event_id || event_time || device_id || action || target || result || prev_event_hash_of_the_event_before_that)`.
The first event on a device has `prev_event_hash = SHA-256(device_id || device_init_time)`.

Any insertion, deletion, or modification of an event in the middle of the chain invalidates all subsequent `prev_event_hash` values, which makes the tampering detectable.

A daily "anchor" event must be written that is also signed by the operator's HSM / KMS key, providing an external anchor that a regulator can verify.

### 4.4 Clock

The device clock must be synchronised to a trusted time source (for example, `time.android.com` over TLS, or your own NTP service).
Drift of more than 60 seconds from the trusted time must itself generate a `device.clock_anomaly` event.

## 5. Access, export, and supervision

### 5.1 Who can read the log

Only the following roles may read the audit log:

- (a) the operator's compliance officer and the compliance officer's delegates;
- (b) the operator's internal audit team and external auditor, under NDA;
- (c) the project owner, on the terms in [TERMS_OF_SERVICE.md §10](terms-of-service)#10-audit-and-inspection);
- (d) law-enforcement and regulators, under a valid legal process.

The log must not be readable by the application that generated the events, or by the operator's customer-facing application.

### 5.2 Export

Every export of the audit log is itself an event (`audit.log_export`).
Exports are signed by the operator's HSM / KMS key and include:

- the range of events exported;
- the requesting party's identity;
- the legal basis for the export (internal review, regulator request, court order);
- a SHA-256 hash of the exported file, signed.

### 5.3 Tamper detection

The operator must run an automated daily job that:

- (a) walks the hash chain and verifies that every `prev_event_hash` matches the previous event;
- (b) verifies the daily anchor signature;
- (c) alerts on any mismatch.

A mismatch must be investigated within 24 hours and must generate a `policy.kill_switch_engaged` event if the mismatch cannot be explained.

## 6. The kill switch

Every device must implement a **kill switch** that, on a signed command from the operator, disables the `RemoteControlService` (and any equivalent API) and prevents further privileged actions.

The kill switch command must be:

- authenticated (mTLS or HSM-signed JWT);
- idempotent (a repeated command is a no-op);
- logged as `device.kill_switch_engaged`.

A device that has been killed must not be re-enabled without an out-of-band authorisation (for example, a phone call to a designated officer at the operator, with the call logged).

## 7. The user's obligations

As a customer subject to this audit-log specification, you must:

- (a) implement the audit log on every device in your fleet that runs a Prebuilt Image;
- (b) retain the log for the applicable period in section 4.2;
- (c) protect the log against tampering in accordance with section 4.3 and section 5.3;
- (d) export and produce the log to the project owner, a law-enforcement agency, or a court of competent jurisdiction within 30 days of a written request;
- (e) not disable, circumvent, or tamper with the audit-log mechanism (this is also a breach of the AUP, section 3.4);
- (f) not use any device that is not subject to a working audit log, except for development and test devices that are clearly labelled as such and that do not interact with production third-party services.

## 8. The technical reference implementation

The `RemoteControlService` in `packages/apps/RemoteControlService/` is intended to implement the event-capture part of this specification natively.
A reference implementation of the remote log sink, the hash-chaining, the daily anchor, and the tamper-detection job is **not yet shipped**.
The current `RemoteControlService` API surface is documented on the `feat/qa-lab-os-v0` worktree; this document is the binding spec until the reference implementation lands.

Until the reference implementation is shipped, this document is the binding spec; the choice of implementation (a SIEM, a managed logging service, a custom log pipeline) is yours, provided it meets the spec.

## 9. Changes to this specification

The project owner may update this specification to reflect changes in the project, in applicable law, or in the threat model.
Material changes will be communicated via a GitHub release note and (for KYC-cleared customers) by direct notice at least 90 days before the change takes effect.

## 10. Not legal advice

Nothing in this document is legal advice. The project owner is not your lawyer. A solicitor qualified in England & Wales must review this document before it is relied on for any specific legal defence or commercial relationship. A security engineer should review the technical specification before it is implemented.
