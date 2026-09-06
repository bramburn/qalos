---
sidebar_position: 4
---

# Acceptable Use Policy

> **DRAFT — not legal advice.**
> This document is a draft for review by a solicitor qualified in England & Wales before reliance.
> See [README.md](index) for the framework context.

**Effective date:** 2026-09-03

This Acceptable Use Policy (the **"AUP"**) lists the uses that are **prohibited** when using the qalos project.
It is incorporated by reference into the [TERMS_OF_SERVICE.md](terms-of-service) (the "ToS").
A breach of the AUP is a breach of the ToS.

If you are unsure whether a use is permitted, the answer is **no**.
Contact the project owner at the address in section 6 before acting.

## 1. Scope

This AUP applies to:

- Use of the qalos source code, including any Prebuilt Image, Derivative, or service built from it.
- Use of the `RemoteControlService` and any successor or equivalent service that exposes a system-level API for input injection, screenshot capture, or application lifecycle control.
- Use of any agent, driver, or test rig that uses qalos as a substrate.

## 2. The permitted baseline

The project is a tool for **software-quality testing of Android applications**.
The baseline permitted use is:

- Driving a device (or emulator) that **you own or have written permission to control** (from yourself, your employer, or your client under a written engagement).
- Testing **applications that you own, or that you have written permission to test** (from the app owner, your employer, or your client under a written engagement).
- Capturing screenshots, injecting input, and starting / stopping apps for the purpose of automating the test.
- Storing the resulting test artefacts (screenshots, logs, video, traces) for QA, regression analysis, and debugging.

Anything outside this baseline must be assessed against the prohibitions below.

## 3. The prohibitions

The following are **prohibited uses**.
The list is illustrative, not exhaustive: anything that is not on the list but that violates section 4 is also prohibited.

### 3.1 Fraud and deception

- **Fake engagement.** Creating, inflating, or simulating any form of engagement that is presented as authentic, including: fake account creation, fake reviews, fake ratings, fake ad impressions, fake clicks, fake video views, fake social-media followers, fake comments, fake "likes", fake "shares", and fake user-generated content of any kind.
- **Affiliate / referral fraud.** Generating fake signups, fake installs, fake trial activations, or fake conversions for the purpose of earning affiliate commissions, referral bonuses, or similar incentives.
- **Ad fraud.** Generating ad impressions, ad clicks, or ad conversions through automated means, including click injection, click flooding, and SDK spoofing.
- **SEO manipulation.** Generating fake backlinks, fake traffic, fake dwell time, fake bounce-rate patterns, or fake "user signals" intended to influence search-engine rankings.
- **KYC / onboarding bypass.** Automating the bypass of identity verification, liveness checks, document capture, sanctions screening, or any other gate designed to verify that a user is a unique human being or a bona fide counterparty.
- **Reward fraud.** Abusing in-app rewards, sign-up bonuses, "new user" promotions, referral chains, and loyalty programmes through automated or multi-account behaviour.

### 3.2 Unauthorised access

- **Testing without permission.** Using the project to drive interactions with any application, service, or platform for which you do **not** have the owner's written permission to test. "It was only a test" is not a defence.
- **Bypassing access controls.** Using the project to bypass CAPTCHAs, rate limits, IP blocks, geo-restrictions, device-fingerprinting, attestation (Play Integrity, DeviceCheck, etc.), or any other access-control mechanism.
- **Credential abuse.** Credential stuffing, password spraying, brute-force login, session hijacking, or token theft. The project is not a credential-testing tool.
- **Bypassing payment.** Using the project to interact with paid services without paying, to manipulate metering, to extend trials beyond their terms, or to circumvent in-app purchases.
- **SIM / device / IMEI fraud.** Modifying device identifiers, SIM identifiers, or any other identifier to evade platform-level bans.

### 3.3 Data misuse

- **Bulk scraping.** Using the project to bulk-scrape personal data, contact data, financial data, health data, or any other data covered by data-protection law (including the UK GDPR, the EU GDPR, the CCPA, or equivalent).
- **Privacy violations.** Capturing screenshots, video, microphone, location, contacts, messages, or other personal data from a device whose owner has not given specific, informed consent to the capture.
- **Spyware / stalkerware.** Installing the project (or any Derivative that preserves the project's capabilities) on a device that is not your own, or on a device whose owner has not given specific, informed consent to the automation.
- **Data exfiltration.** Using the project to extract data from a device or service in a manner that violates the owner's terms or applicable law.

### 3.4 Integrity, safety, and the audit mechanism

- **Disabling audit.** Disabling, circumventing, or tampering with the audit-logging mechanism described in [AUDIT_LOGGING.md](audit-logging), where such a mechanism is built into the project or required by a contract.
- **Hiding the build source.** Distributing a Prebuilt Image or Derivative without the required source-availability, attribution, or trade-mark notice under the Software Licence.
- **Removing safety rails.** Removing or weakening the confirmation dialogs, rate limits, allow-lists, or any other safety rail built into the project.
- **Reverse-engineering for harm.** Reverse-engineering the project's safety, security, or audit mechanisms for the purpose of bypassing them (studying them under the Software Licence is permitted).

### 3.5 Regulated, restricted, and high-risk uses

- **Sanctions.** Using the project in, or for the benefit of a person or entity in, any country or territory that is the subject of comprehensive sanctions, or in violation of any Sanctions List.
- **Export-controlled use.** Using the project in any manner that requires an export licence under UK, US, or EU export-control law without first obtaining that licence. The project's source code is publicly available, but the operational use of an automation rig may attract export-control obligations depending on the destination and the use case.
- **Critical infrastructure.** Using the project as a control system, component, or test rig for any safety-critical system (medical devices, aviation, nuclear, rail signalling, autonomous vehicles, energy grid, financial-market infrastructure, life-safety) without a separate written agreement with the project owner.
- **Weapons and military end-use.** Using the project in the design, production, operation, or testing of weapons, weapons systems, or military equipment, or providing it to a military end-user.
- **Surveillance for control.** Using the project for mass surveillance, social-scoring, or any other use that is illegal under the law of the jurisdiction in which the target is located.

### 3.6 Commercial and resale restrictions

- **Reselling prebuilt images to unverified parties.** A third party who receives a Prebuilt Image from you must go through the KYC process in [KYC.md](kyc) before you ship.
- **Reselling as a "clean" OS.** Marketing a Derivative as "untraceable", "anonymous", "undetectable", "stealth", "fingerprint-clean", or in any way that emphasises evasion of platform-level detection, is prohibited.
- **Reselling the trade name.** Selling a Prebuilt Image, Derivative, or hosted service under the "qalos" or "QA Lab Operating System" trade name without the trade-mark licence in the ToS is prohibited.

## 4. The general principle

Even if a use is not listed above, it is prohibited if it:

- (a) is illegal in your jurisdiction or in the jurisdiction of the data subjects;
- (b) infringes a third-party right (intellectual property, privacy, contractual);
- (c) is intended to deceive, defraud, or harm a third party; or
- (d) would, in the reasonable view of the project owner, materially increase the project owner's legal exposure if the project owner became aware of it.

## 5. Enforcement

5.1. **The project owner's right to act.** If the project owner becomes aware of a use that violates this AUP, the project owner may, in addition to its rights under the ToS:

- (a) publicly identify the use (with appropriate redactions) in a transparency report;
- (b) report the use to the relevant law-enforcement or regulator;
- (c) cooperate with law enforcement, including by producing the Audit Log if one exists.

5.2. **No monitoring duty.** The project owner has no obligation to monitor use. The right to act in section 5.1 does not create a duty to monitor.

5.3. **Defence by the user.** If you believe a use has been incorrectly identified as a violation, you may respond to the project owner with evidence. The project owner will consider the response in good faith but is not obliged to reverse a transparency-report decision before publication.

## 6. Reporting suspected violations

6.1. If you believe a user of the project is in breach of this AUP, you may report it to the project owner at the address in [TERMS_OF_SERVICE.md §14](terms-of-service)#14-contact).

6.2. Reports should include: the user (if known), the use (with as much specificity as you can share without violating another person's rights), the evidence (logs, screenshots, public records), and your contact details so the project owner can follow up.

6.3. Reports are handled in confidence to the maximum extent consistent with the project owner's legal obligations.

## 7. Not legal advice

Nothing in this document is legal advice. The project owner is not your lawyer. A solicitor qualified in England & Wales must review this document before it is relied on for any specific legal defence or commercial relationship.
