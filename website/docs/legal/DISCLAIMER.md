---
sidebar_position: 2
---

# Disclaimer

> **DRAFT — not legal advice.**
> This document is a draft for review by a solicitor qualified in England & Wales before reliance.
> See [README.md](index.md) for the framework context.

**Effective date:** 2026-09-03
**Applies to:** all versions of qalos, including the source code in this repository, any binary image built from it,
and any service that exposes a qalos-derived API.

## 1. The parties

For the purposes of this disclaimer:

- **"the project"** means the qalos repository at <https://github.com/bramburn/qalos>, the **QA Lab Operating System** trade name, and any version, fork, or derivative published from it.
- **"the project authors"** means **Bhavesh Ramburn** (the natural person, GitHub handle `bramburn`) and **Icelabz Solutions Ltd** (the company), together with their employees, agents, contractors, and assignees.
- **"you"** means the person or entity that downloads, builds, runs, distributes, resells, integrates, or otherwise uses the project, including any employee, contractor, or agent acting on your behalf.
- **"contributors"** means anyone who has submitted a pull request, issue, comment, or other contribution to the project, and who has (or is deemed to have) accepted the [CLA.md](CLA.md).

## 2. The project is a tool, not a service

The project is a fork of the Android Open Source Project (AOSP) customised for QA testing.
The source code is licensed under the MIT licence (with bundled AOSP components under Apache 2.0);
see [LICENSE](https://github.com/bramburn/qalos/blob/main/LICENSE).
Nothing in this disclaimer changes those licences.

This disclaimer **adds** restrictions on use; it does not grant additional rights beyond the licence.

## 3. Intended use

The project is intended for:

- Software-quality testing of Android applications that **you own or have written permission to test**.
- Internal automation, CI, and research on hardware that **you control**.
- Educational use (for example, learning Android internals, AOSP build systems, or test automation).
- Any other lawful purpose that does not violate the [ACCEPTABLE_USE_POLICY.md](ACCEPTABLE_USE_POLICY.md).

## 4. No warranty

The project is provided **"as is" and "as available"**, without warranty of any kind, express or implied, including but not limited to:

- The warranties of merchantability, fitness for a particular purpose, and non-infringement.
- The warranties of accuracy, completeness, or currency of the documentation.
- The warranty that the project will be uninterrupted, error-free, secure, or free from harmful components.
- The warranty that any defect will be corrected.

Some jurisdictions do not allow the exclusion of certain warranties; in those jurisdictions, the exclusions above apply to the maximum extent permitted by law and the remaining warranties are limited to the minimum duration required by law.

## 5. No liability

To the maximum extent permitted by law, **the project authors and contributors shall not be liable** for any claim, demand, damages, loss, cost, or expense (including reasonable legal fees) arising out of or in connection with:

- Your access to, use of, or inability to use the project.
- Your violation of any applicable law, regulation, or third-party right.
- Any conduct of any third party on or through the project.
- Any unauthorised access to, alteration of, or loss of your data or devices.
- Any fraud, illegal act, or regulatory breach committed by you or by a third party using a device or service you operate.

The limitations in this section apply whether the claim is based on contract, tort (including negligence), statute, or any other legal theory, and even if the project authors or contributors have been advised of the possibility of such damages.

In jurisdictions that do not allow the exclusion or limitation of certain damages (for example, liability for death or personal injury caused by negligence, or fraud), the project authors' and contributors' liability is limited to the maximum extent permitted by law.

## 6. You are responsible for your use

The project is a tool. **You are solely responsible for the legality of your use of it.**
This includes, without limitation:

- Verifying that the applications you automate with qalos are your own, or that you have written permission to test them.
- Complying with the terms of service of any third-party platform or service you interact with via a qalos-driven device.
- Complying with applicable data-protection, anti-fraud, anti-money-laundering, sanctions, export-control, and consumer-protection laws.
- Maintaining the audit logs required by [AUDIT_LOGGING.md](AUDIT_LOGGING.md) if you operate a fleet or resell a derivative.
- Completing the KYC process in [KYC.md](KYC.md) if you receive prebuilt images, commercial support, or hosted services.

## 7. High-risk uses

The following uses are **specifically called out as high-risk** and are the reason the [KYC.md](KYC.md) and [AUDIT_LOGGING.md](AUDIT_LOGGING.md) documents exist:

- Operating fleets of devices that interact with third-party services the operator does not own.
- Creating fake accounts, fake reviews, fake ad impressions, or fake engagement.
- Credential stuffing, session hijacking, or bypassing rate limits or CAPTCHAs.
- Bulk scraping of personal data.
- Any use that is illegal in the operator's jurisdiction or in the jurisdiction of the data subjects.

If you are considering any of the above, the project is **not** the right tool for you.

## 8. Indemnity (back-up)

Without prejudice to the indemnity clause in [TERMS_OF_SERVICE.md](TERMS_OF_SERVICE.md), you agree to indemnify and hold harmless the project authors and contributors from any third-party claim arising out of your use of the project in breach of this disclaimer, the ToS, the AUP, or applicable law.

## 9. No agency

Nothing in this disclaimer creates a partnership, joint venture, agency, employment, or franchise relationship between you and the project authors.

## 10. Severability

If any provision of this disclaimer is held to be invalid or unenforceable, the remaining provisions remain in full force and effect.

## 11. Governing law

This disclaimer is governed by the laws of England and Wales. Disputes are subject to the exclusive jurisdiction of the courts of England and Wales, except where an applicable mandatory consumer-protection law says otherwise.

## 12. Changes

The project authors may update this disclaimer to reflect changes in the project, in applicable law, or in the risk profile of the project.
Material changes will be communicated via a GitHub release note and (for commercial customers) by direct notice.
The current version always lives in this repository.

## 13. Contact

- **General legal queries:** open a GitHub issue labelled `legal`.
- **Confidential legal matters:** email the maintainer at the address listed in the GitHub profile.
- **Security vulnerabilities:** follow [SECURITY.md](SECURITY.md); do **not** file a public issue.

## 14. Not legal advice

Nothing in this document is legal advice. The project authors are not your lawyer. A solicitor qualified in England & Wales must review this document before it is relied on for any specific legal defence or commercial relationship.
