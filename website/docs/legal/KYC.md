---
sidebar_position: 5
---

# Know-Your-Customer (KYC) Policy

> **DRAFT — not legal advice.**
> This document is a draft for review by a solicitor qualified in England & Wales before reliance.
> See [README.md](index.md) for the framework context.

**Effective date:** 2026-09-03

## 1. Why this exists

The qalos project ships capability that is **dual-use**.
Used for its intended purpose — software-quality testing of apps the user owns or has permission to test — it is benign and useful.
Used for one of the prohibited uses listed in the [ACCEPTABLE_USE_POLICY.md](ACCEPTABLE_USE_POLICY.md) — fake accounts, credential stuffing, ad fraud, mass scraping — it is harmful and illegal.

The project author, the company, and the contributors cannot prevent misuse by technical means alone (the source is public, the build is reproducible).
The next-best defence is to **screen the people who receive prebuilt images, hosted services, or commercial support**, and to **require them to keep an audit log** (see [AUDIT_LOGGING.md](AUDIT_LOGGING.md)).

This document sets out the KYC process.
It is incorporated by reference into the [TERMS_OF_SERVICE.md](TERMS_OF_SERVICE.md) and applies to **every commercial customer** of the project.

## 2. Who must complete KYC

KYC is mandatory for:

- **Prebuilt-image recipients.** Anyone who receives a bootable system image built from the project source, where the image is provided by the project owner or by a downstream reseller.
- **Hosted-service users.** Anyone who uses a hosted service that exposes a project-derived API (for example, a hosted `RemoteControlService` endpoint, a hosted device farm, or a hosted "QA as a service" offering that runs qalos).
- **Commercial support customers.** Anyone who pays for, or receives in-kind, support, customisation, integration help, or training from the project owner.
- **Resellers.** Anyone who intends to distribute Prebuilt Images, Derivatives, or hosted services to third parties (the reseller completes KYC; the reseller is responsible for downstream KYC of its own customers, subject to the project owner's audit right).
- **High-volume source users.** The project owner may, at its sole discretion, require KYC from a source-only user whose download volume, build frequency, or distribution pattern suggests commercial use.

KYC is **not** required for:

- Casual users who clone the project source and build a Prebuilt Image for their own non-commercial use, without requesting the project owner's prebuilt image, hosted service, or commercial support.
- Students using the project for coursework, learning, or non-commercial research.
- Contributors who submit pull requests, issues, or comments (contributors are covered by the [CLA.md](CLA.md) instead).

## 3. What we collect

For a corporate customer, we collect:

- **Entity details.** Legal name, trading name, registered number, registered address, country of incorporation, jurisdiction of operations, and ultimate parent (if any).
- **Beneficial owners.** Names, dates of birth, nationalities, and residential addresses of natural persons who ultimately own or control 25% or more of the entity. For a trust or partnership, the trustees or general partners.
- **Directors and authorised signatories.** Names, dates of birth, and roles.
- **Identification documents.** For each beneficial owner and director: a copy of a government-issued photo ID (passport, national ID, or driving licence) and a recent proof of address (utility bill or bank statement, less than three months old).
- **Business purpose.** A written description of the customer's intended use of the project: what they are testing, who the app owner is, what jurisdiction they are operating in, what volume of devices they intend to run, and what their data-handling policy is.
- **Sanctions screening.** A check that the entity, its beneficial owners, and its directors are not on the UK Sanctions List, OFAC's SDN list, the EU consolidated list, or the UN Security Council consolidated list.
- **Adverse-media screening.** A check of open-source adverse-media reports for the entity, its beneficial owners, and its directors (sanctions, criminal proceedings, regulator action, fraud).
- **PEP screening.** Whether any beneficial owner or director is a politically exposed person (PEP) as defined in the Money Laundering, Terrorist Financing and Transfer of Funds (Information on the Payer) Regulations 2017.

For an individual customer (sole trader, freelancer, hobbyist running a small commercial setup), we collect the same set, with the entity being the individual.

## 4. How we verify

We use a tiered approach:

- **Tier 1 — Self-attestation.** The customer completes a structured intake form, attests to the accuracy of the information, and consents to verification.
- **Tier 2 — Documentary verification.** We request and review the identification documents in section 3.
- **Tier 3 — Independent verification.** For higher-risk customers (high-volume, regulated industry, PEP exposure, adverse-media hit, jurisdiction of concern), we use a third-party KYC / AML vendor (for example, Onfido, Veriff, Jumio, Sumsub, or equivalent) to perform document authentication, liveness check, and sanctions / adverse-media screening.
- **Tier 4 — Enhanced due diligence (EDD).** For the highest-risk cases, we require an in-person or video interview, a site visit, a site visit to the customer's test facility, or a third-party audit report. EDD is at the project owner's discretion and the cost is borne by the customer.

The verification tier is set by the project owner based on a risk assessment of the customer, the intended use, and the volume.

## 5. How we use the information

We use KYC information to:

- (a) verify the identity of the customer and its beneficial owners;
- (b) screen for sanctions, PEP, and adverse media;
- (c) assess the risk of the customer's intended use of the project;
- (d) decide whether to enter into, continue, or terminate the commercial relationship;
- (e) comply with our legal obligations under UK anti-money-laundering (AML), counter-terrorist-financing (CTF), and sanctions law;
- (f) cooperate with law-enforcement and regulator requests.

We **do not**:

- (a) sell or rent KYC information to third parties;
- (b) use KYC information for marketing without separate consent;
- (c) share KYC information with anyone outside the project owner except as required by law, except with the customer's consent (for example, to a reseller), or except with our KYC vendor under a written data-processing agreement.

## 6. How long we keep it

We retain KYC information for the duration of the commercial relationship and for **seven (7) years** after the relationship ends.
This satisfies the UK MLR 2017 record-keeping requirement (regulation 40) for any customer that we have classified as falling within the AML regulated sector (we may opt to apply this retention period to all customers as a matter of policy, regardless of statutory obligation).

On expiry, we delete the information from our active systems within 30 days.
Backup copies are deleted in line with our standard backup rotation (typically within 90 days).
We may retain a record that KYC was completed (without the underlying documents) for the same period, to evidence that the relationship was appropriately screened.

## 7. Refusal and revocation

7.1. **Refusal.** The project owner may refuse to enter into a commercial relationship, supply a Prebuilt Image, or grant access to a hosted service, if:

- (a) the customer fails to provide the information required by section 3;
- (b) the verification in section 4 reveals a sanctions, PEP, or adverse-media hit that the project owner cannot or does not wish to mitigate;
- (c) the customer's stated business purpose is inconsistent with the [ACCEPTABLE_USE_POLICY.md](ACCEPTABLE_USE_POLICY.md) or with the project owner's risk appetite;
- (d) the customer is in a jurisdiction that is the subject of comprehensive sanctions;
- (e) the project owner, in its sole discretion, determines that the relationship would materially increase its legal exposure.

7.2. **Revocation.** The project owner may revoke access, terminate the ToS under [TERMS_OF_SERVICE.md §6.3](TERMS_OF_SERVICE.md)#6-term-and-termination), and require the return or destruction of any Prebuilt Image, if:

- (a) any of the circumstances in section 7.1 come to light after the relationship has started;
- (b) the customer breaches the AUP, the Audit-Log terms, or any other provision of the ToS;
- (c) a regulator or law-enforcement agency directs the project owner to do so.

7.3. **Appeals.** The customer may appeal a refusal or revocation in writing within thirty (30) days. The project owner will consider the appeal in good faith but is not obliged to reverse the decision.

## 8. Data protection

We process KYC information as a data controller under the UK GDPR and the Data Protection Act 2018.
Our lawful basis is:

- (a) **Legal obligation** (Article 6(1)(c)) for AML / sanctions screening, where applicable.
- (b) **Legitimate interests** (Article 6(1)(f)) for risk assessment, fraud prevention, and enforcement of the ToS.
- (c) **Contract** (Article 6(1)(b)) for processing necessary to enter into and perform the commercial relationship.

Data-subject rights (access, rectification, erasure, restriction, objection, portability) apply as set out in the UK GDPR.
We may refuse erasure during the retention period in section 6 where the right is overridden by a legal obligation or legitimate interest.

A full privacy notice is published at [PRIVACY.md](PRIVACY.md) (forthcoming) and is provided to every KYC subject as part of the intake form.

## 9. Cooperation with law enforcement

We cooperate with lawful requests from UK law-enforcement agencies, the National Crime Agency, the Information Commissioner's Office, OFSI, and equivalent bodies in other jurisdictions under applicable mutual-legal-assistance treaties.
We will, on receipt of a valid request:

- (a) confirm whether a named individual or entity is a customer;
- (b) produce the Audit Log required by [AUDIT_LOGGING.md](AUDIT_LOGGING.md) for that customer, where we have lawful access to it;
- (c) produce KYC information, subject to our legal-rights analysis on a case-by-case basis.

We will challenge requests that are overbroad, unlawful, or contrary to human-rights obligations, and we will notify the customer of any request unless we are legally prohibited from doing so.

## 10. Not legal advice

Nothing in this document is legal advice. The project owner is not your lawyer. A solicitor qualified in England & Wales must review this document before it is relied on for any specific legal defence or commercial relationship. In particular, the KYC thresholds and the AML/CTF analysis in this document should be reviewed by a solicitor who specialises in financial-crime compliance.
