---
sidebar_position: 8
---

# Security Policy

> **DRAFT — not legal advice.**
> This document is a draft for review by a solicitor qualified in England & Wales before reliance.
> See [README.md](index) for the framework context.

**Effective date:** 2026-09-03

## 1. Scope

This security policy applies to **security vulnerabilities in the qalos project itself** — that is:

- Source code under `device/qalos/`, `packages/apps/QaLab/`, `packages/apps/RemoteControlService/`, `tools/`, and `scripts/`.
- The build manifests in `default.xml` (the qalos-specific pins, not the AOSP upstream).
- The documentation, where it would lead a user to a vulnerable configuration.
- The CI / GitHub-side configuration in `.github/`.

**Out of scope** (please report these to the upstream projects instead):

- **AOSP itself.** Report to <https://source.android.com/> and <https://issuetracker.google.com/>.
- **GitHub Actions, PSScriptAnalyzer, shellcheck, gitleaks, or other CI tools.** Report to the respective maintainers.
- **The Docusaurus site engine, the Node.js runtime, or the npm supply chain.** Report upstream.
- **The `qalos` repo infrastructure (branch protection, GitHub-side settings).** Email the maintainer.

## 2. How to report

### 2.1 Preferred: GitHub private vulnerability reporting

1. Go to <https://github.com/bramburn/qalos/security/advisories/new>.
2. Fill in the advisory form.
3. Submit. The report is delivered privately to the maintainer.

This is the preferred channel because:

- the report is delivered privately, not on a public issue tracker;
- you can collaborate with the maintainer on a fix in a private thread;
- the report becomes a GitHub Security Advisory, which carries a CVE request flow on publication.

### 2.2 Alternative: email

If you cannot or do not wish to use GitHub private vulnerability reporting, email the maintainer at the address in the GitHub profile.
Use PGP if you can — the maintainer's PGP key is published at <https://github.com/bramburn.gpg> (forthcoming; until then, use Signal or ProtonMail for sensitive content).

### 2.3 What to include

- A clear description of the vulnerability, including the impact and a CVSSv3.1 vector if you have one.
- The affected component, file, commit SHA, and (if relevant) the affected version tag.
- A reproducer: steps to reproduce, a proof-of-concept script, or a screen recording. A working reproducer materially accelerates triage.
- Your name and how you would like to be credited in the advisory (or "anonymous" if you prefer).
- Whether you intend to disclose publicly, and on what timeline.

## 3. Our commitments

### 3.1 Acknowledgement

We will acknowledge a new report within **three (3) business days** of receipt.

### 3.2 Triage

We will triage the report (confirm the bug, assess severity, decide on a fix) within **seven (7) business days** of acknowledgement.
For a critical report (CVSS 9.0+ or active exploitation), triage is within **twenty-four (24) hours**.

### 3.3 Fix

We aim to ship a fix within the following timelines (measured from triage, not from report):

| Severity (CVSSv3.1) | Target fix window |
| --- | --- |
| Critical (9.0-10.0) | 7 days |
| High (7.0-8.9) | 30 days |
| Medium (4.0-6.9) | 90 days |
| Low (0.1-3.9) | Next minor release |

If we cannot meet the target for a justified reason (for example, the fix depends on an AOSP upstream change), we will publish a public timeline and, where possible, an interim mitigation in the advisory.

### 3.4 Coordinated disclosure

We ask that you do not disclose the vulnerability publicly until we have shipped a fix, or until the agreed disclosure date, whichever is earlier.
The default disclosure window is **90 days** from acknowledgement, in line with the Google Project Zero disclosure policy.
Extensions are negotiable on request.

If you have a deadline (for example, a conference talk), please tell us at report time and we will work with you.

### 3.5 Credit

With your consent, we will credit you in the published advisory.
If you do not consent, we will not.

## 4. Safe harbour

We will not pursue legal action against, request law enforcement to investigate, or restrict your account on the basis of, a good-faith security research activity that:

- (a) is reported to us through the channels in section 2;
- (b) avoids privacy violations, data destruction, and disruption of the service;
- (c) stops as soon as a vulnerability is confirmed and does not exploit it beyond what is necessary to demonstrate the vulnerability;
- (d) complies with applicable law.

This safe harbour is intended to be consistent with the [Disclosure.org](https://disclose.io/) principles and the [CVD](https://github.com/distributedweaknessfiling/cvdf) guide.

We will not waive any term of an existing agreement (for example, a KYC agreement, a commercial licence, or an employment contract) without your consent.

## 5. Security update policy

### 5.1 Supported versions

The current `main` branch is supported with security fixes.
Branches older than the latest minor release are not, unless a commercial support contract says otherwise.

### 5.2 Patches

Security fixes are released as:

- a commit on `main`, and
- a backport PR to the current minor release branch (if any), and
- a GitHub Security Advisory with a CVE (if the vulnerability merits one).

We do not currently ship binary patches; users running prebuilt images should rebuild from the patched source.

### 5.3 Prebuilt-image customers

If you operate a fleet of prebuilt images, you are responsible for tracking security advisories and rebuilding / re-imaging promptly.
The project owner is not responsible for the security of a device that has not been patched, even if the patch is available.

## 6. Cryptography

### 6.1 Transport

All maintainer-side endpoints that handle vulnerability reports use TLS 1.2 or later, with modern cipher suites.
Email is not a confidential channel by default; please use PGP or GitHub private vulnerability reporting.

### 6.2 Source integrity

Releases are tagged in git; consumers should verify the tag's signing key.
The maintainer's signing key fingerprint is published at <https://github.com/bramburn.gpg> (forthcoming).

## 7. Coordinated vulnerability handling across the supply chain

The qalos project depends on AOSP and a small number of CI / build-time tools.
We coordinate with the relevant upstream maintainers when a vulnerability in our code is rooted in an upstream dependency, and we publish an advisory that points to the upstream advisory.

We do not currently participate in any formal CNA (CVE Numbering Authority) arrangement.

## 8. Hall of fame

Researchers who have contributed a confirmed, fixed vulnerability will be listed in [HALL_OF_FAME.md](HALL_OF_FAME.md) (forthcoming) with their consent.

## 9. Contact

- **Vulnerability report:** see section 2.
- **General security question (not a vulnerability):** open a GitHub issue labelled `security-question`.
- **Confidential security matter** (partnership, supply-chain, hardening of a commercial deployment): email the maintainer at the address in the GitHub profile.

## 10. Not legal advice

Nothing in this document is legal advice. The project owner is not your lawyer. A solicitor qualified in England & Wales must review this document before it is relied on for any specific legal defence or commercial relationship.
