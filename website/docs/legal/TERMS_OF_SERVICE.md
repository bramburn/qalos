---
sidebar_position: 3
---

# Terms of Service

> **DRAFT — not legal advice.**
> This document is a draft for review by a solicitor qualified in England & Wales before reliance.
> See [README.md](index) for the framework context.

**Effective date:** 2026-09-03

These Terms of Service (the **"ToS"**) form a binding agreement between **you** (the user) and **Icelabz Solutions Ltd** (the **"project owner"**) in respect of the qalos project (the **"project"**).
By downloading, building, running, distributing, or otherwise using the project, you accept these ToS.
If you do not accept these ToS, you must not use the project.

## 1. Definitions

- **"Audit Log"** has the meaning given in [AUDIT_LOGGING.md](audit-logging).
- **"Authorised Use"** means a use that complies with the [ACCEPTABLE_USE_POLICY.md](acceptable-use-policy) and all applicable laws.
- **"Commercial Use"** means any use of the project by a business, organisation, or for the purpose of providing goods or services to a third party (including operating a fleet, reselling images, or providing hosted services).
- **"Derivative"** means any modified version, image, or service based on the project source.
- **"KYC"** has the meaning given in [KYC.md](kyc).
- **"Prebuilt Image"** means a bootable system image built from the project source, whether produced by the project owner or by a third party.
- **"Project IP"** means the copyright, trademark, patent, design right, database right, and any other intellectual-property right in the project, including the source code, the documentation, the trade names "qalos" and "QA Lab Operating System", and the build tooling.
- **"Sanctions List"** means any list of sanctioned persons, entities, or territories maintained by the United Kingdom (including the UK Sanctions Regulations and the OFSI consolidated list), the United States (including OFAC's SDN list), the European Union, or the United Nations.
- **"Software Licence"** means the MIT Licence (for original qalos contributions) and the Apache 2.0 Licence (for bundled AOSP components), as set out in [LICENSE](https://github.com/bramburn/qalos/blob/main/LICENSE).
- **"User"**, **"you"**, and **"your"** mean the person or legal entity accepting these ToS.

## 2. Acceptance and eligibility

2.1. **Acceptance.** You accept these ToS by doing any of the following: (a) downloading, cloning, or otherwise obtaining a copy of the project source; (b) building a Prebuilt Image; (c) running a Prebuilt Image on any device; (d) distributing a Prebuilt Image or Derivative; (e) accessing any service that exposes a project-derived API.

2.2. **Capacity.** If you accept these ToS on behalf of an entity, you represent and warrant that you have the authority to bind that entity.

2.3. **Eligibility.** You represent and warrant that:

- (a) You are not located in, and you are not a national or resident of, any country or territory that is the subject of comprehensive sanctions.
- (b) You are not listed on any Sanctions List, and you are not owned or controlled by any person or entity so listed.
- (c) You are not otherwise prohibited by law from receiving or using the project.
- (d) If you are an individual, you are at least 18 years old.

2.4. **Commercial Use requires KYC.** If your use is Commercial Use, or if you receive a Prebuilt Image or hosted service from the project owner, you must complete the KYC process in [KYC.md](kyc) before such use or receipt. The project owner may refuse or revoke Commercial Use, Prebuilt Image delivery, or hosted-service access at its sole discretion.

## 3. Licence grant (and how it interacts with the Software Licence)

3.1. **Software Licence prevails.** The Software Licence sets out the terms on which you may use, copy, modify, and distribute the project source. Nothing in these ToS reduces the rights granted by the Software Licence.

3.2. **Trade-mark licence.** The project owner grants you a personal, non-exclusive, non-transferable, revocable licence to use the trade names "qalos" and "QA Lab Operating System" solely:

- (a) to refer to the project in a non-misleading way (for example, in academic papers, technical documentation, or news articles); and
- (b) on Prebuilt Images that you have built from the project source unmodified, in compliance with the trade-mark attribution in the [BRAND_GUIDELINES.md](BRAND_GUIDELINES.md) (forthcoming).

You may not use the trade names in any manner that suggests endorsement by the project owner, that disparages the project, or that violates the AUP.

3.3. **No other rights.** Except as expressly stated in the Software Licence or this section, no rights are granted to you under any patent, trade mark, trade secret, copyright, or other intellectual-property right of the project owner.

## 4. Your obligations

4.1. **Lawful use.** You must use the project only for Authorised Use and only in compliance with all applicable laws and regulations.

4.2. **AUP.** You must not use, and must not permit any third party to use, the project for any use prohibited by the [ACCEPTABLE_USE_POLICY.md](acceptable-use-policy).

4.3. **Third-party rights.** You must not use the project in any manner that infringes the rights of any third party (including intellectual-property rights, privacy rights, and contractual rights).

4.4. **Audit Log.** If your use requires an Audit Log under [AUDIT_LOGGING.md](audit-logging), you must:

- (a) maintain the Audit Log in accordance with that document;
- (b) produce the Audit Log to the project owner, to a law-enforcement agency, or to a court of competent jurisdiction within thirty (30) days of a written request;
- (c) cooperate with any reasonable investigation by the project owner into compliance with this section; and
- (d) not disable, circumvent, or tamper with any audit-logging mechanism built into the project.

4.5. **No reverse-engineering of safety mechanisms.** You must not reverse-engineer, disable, or circumvent any safety, security, rate-limit, audit-log, or kill-switch mechanism built into the project. (You may, of course, study the project source under the Software Licence.)

4.6. **Notice of misuse.** If you become aware of any use of the project that violates the AUP or that you reasonably suspect to be unlawful, you must promptly notify the project owner at the address in section 14.

## 5. The project owner's obligations

5.1. **Provision.** The project owner will use reasonable efforts to make the project source available, but the project is provided "as is" and the project owner does not guarantee continuous availability, error-free operation, or any specific level of support.

5.2. **Security.** The project owner will follow the [SECURITY.md](security) process for vulnerability disclosure and will use reasonable efforts to address confirmed security vulnerabilities in the project source.

5.3. **No monitoring.** Except as required by law, the project owner does not monitor, and has no obligation to monitor, your use of the project. The project source is distributed; the project owner has no visibility into your build, your fleet, or your derivatives.

## 6. Term and termination

6.1. **Term.** These ToS apply for as long as you use, distribute, or have in your possession any part of the project.

6.2. **Termination by you.** You may terminate these ToS at any time by ceasing all use of the project and deleting all copies in your possession or control (including any Prebuilt Image and any Audit Log that you are not legally required to retain).

6.3. **Termination by the project owner.** The project owner may terminate your right to use the project, the trade-mark licence, and any hosted-service access, with or without notice, if:

- (a) you breach any provision of these ToS, the AUP, the KYC terms, or the Audit-Log terms, and you fail to remedy the breach within fourteen (14) days of written notice (if remediable);
- (b) you are listed on a Sanctions List, or you become the subject of a regulator action that, in the project owner's reasonable view, materially increases the project owner's legal exposure;
- (c) you become insolvent, enter administration, or otherwise cease to be a going concern;
- (d) continued provision would, in the project owner's reasonable view, violate applicable law.

6.4. **Effect of termination.** On termination:

- (a) all rights granted to you under these ToS immediately cease;
- (b) the Software Licence is unaffected — your rights under the Software Licence continue as set out there;
- (c) you must cease all use of the trade names and remove the trade-name attribution from any Derivative that you distribute; and
- (d) any provision of these ToS that by its nature should survive termination (including sections 4, 7, 8, 9, 11, and 14) survives.

## 7. Disclaimers (warranty)

7.1. **No warranty.** To the maximum extent permitted by law, the project owner disclaims all warranties, whether express, implied, or statutory, including the warranties of merchantability, fitness for a particular purpose, non-infringement, accuracy, and quiet enjoyment.

7.2. **No advice.** The project is a tool. Nothing in the project, the documentation, the website, or any communication by the project owner constitutes legal, regulatory, financial, or professional advice.

## 8. Limitation of liability

8.1. **Cap.** To the maximum extent permitted by law, the project owner's aggregate liability to you for all claims arising out of or in connection with these ToS is limited to the greater of (a) the amount you have paid the project owner in the twelve (12) months preceding the claim, or (b) one hundred pounds sterling (£100).

8.2. **Excluded damages.** To the maximum extent permitted by law, in no event will the project owner be liable for any indirect, incidental, special, consequential, exemplary, or punitive damages; loss of profits, revenue, business, goodwill, or anticipated savings; loss or corruption of data; or cost of substitute services, even if the project owner has been advised of the possibility of such damages.

8.3. **Mandatory law.** Nothing in this section limits any liability that cannot be excluded by applicable law (including liability for death or personal injury caused by negligence, or for fraud).

## 9. Indemnity

9.1. **By you.** You will indemnify, defend, and hold harmless the project owner, its officers, employees, agents, and contractors, and the contributors (the **"indemnified parties"**), from and against any third-party claim, demand, action, proceeding, loss, liability, damage, cost, or expense (including reasonable legal fees) arising out of or in connection with:

- (a) your use of the project (including any Authorised Use that nevertheless attracts a third-party claim);
- (b) your breach of these ToS, the AUP, the KYC terms, or the Audit-Log terms;
- (c) your violation of any applicable law or third-party right; or
- (d) your distribution of any Derivative.

9.2. **By the project owner.** The project owner will indemnify you against any third-party claim that the unmodified project source, as distributed by the project owner, infringes a copyright, trade mark, or registered design right of a third party, provided that:

- (a) you promptly notify the project owner of the claim;
- (b) the project owner has sole control of the defence and any settlement; and
- (c) you provide reasonable cooperation.

9.3. **Exclusion.** The project owner's indemnity in section 9.2 does not apply to a claim arising from: (a) any modification of the project source; (b) any combination of the project source with any other software, hardware, or data; (c) your failure to use a non-infringing alternative made available by the project owner; (d) your continued use after notice of infringement; or (e) any Prebuilt Image that you build, distribute, or operate.

## 10. Audit and inspection

10.1. The project owner may, on thirty (30) days' written notice, audit your compliance with sections 4.2, 4.3, 4.4, and 4.5 if the project owner has a reasonable, good-faith belief that you are in breach of those sections.
The audit will be conducted during business hours, will not unreasonably interfere with your operations, and will be at the project owner's cost unless the audit reveals a material breach, in which case you will reimburse the project owner's reasonable costs.

## 11. Governing law and disputes

11.1. **Governing law.** These ToS are governed by the laws of England and Wales, excluding its conflict-of-laws rules.

11.2. **Jurisdiction.** The courts of England and Wales have exclusive jurisdiction over any dispute arising out of or in connection with these ToS, except that either party may seek injunctive or other equitable relief in any court of competent jurisdiction to protect its intellectual-property rights or confidential information.

11.3. **Consumer rights.** Nothing in this section limits any non-excludable right that you have as a consumer under the law of your habitual residence.

11.4. **Pre-action protocol.** Before commencing court proceedings (other than for injunctive relief), the parties will attempt in good faith to resolve the dispute by senior-executive discussion for a period of thirty (30) days from written notice of the dispute.

## 12. Changes to these ToS

12.1. The project owner may update these ToS to reflect changes in the project, in applicable law, or in the risk profile of the project.
Material changes will be communicated via a GitHub release note and (for commercial customers and for users subject to KYC) by direct notice at least thirty (30) days before the change takes effect.
Continued use after the effective date of a change constitutes acceptance of the updated ToS.

## 13. General

13.1. **Entire agreement.** These ToS, together with the Software Licence, the AUP, the KYC terms, the Audit-Log terms, and the [DISCLAIMER.md](disclaimer), constitute the entire agreement between you and the project owner in respect of the project.

13.2. **No waiver.** Failure or delay by the project owner to enforce any provision is not a waiver of that provision.

13.3. **Severability.** If any provision is held invalid or unenforceable, the remaining provisions remain in full force and effect, and the invalid provision will be replaced by an enforceable provision that most closely reflects the original intent.

13.4. **Assignment.** The project owner may assign these ToS to any successor or acquirer. You may not assign these ToS without the project owner's prior written consent.

13.5. **Third-party beneficiaries.** Contributors are third-party beneficiaries of the warranty disclaimers in section 7 and the liability cap in section 8, with the right to enforce those provisions directly. Otherwise, these ToS do not create any third-party rights under the Contracts (Rights of Third Parties) Act 1999.

13.6. **Force majeure.** Neither party is liable for any delay or failure to perform (other than payment obligations) caused by events outside its reasonable control.

13.7. **Notices.** Notices to the project owner must be sent by email to the address in section 14. A notice is deemed received on the next business day after sending, unless bounced.

## 14. Contact

- **General legal queries:** open a GitHub issue labelled `legal`.
- **Confidential legal matters** (proposed amendments, partnership, commercial licence, indemnity negotiation): email the maintainer at the address listed in the GitHub profile.
- **Security vulnerabilities:** follow [SECURITY.md](security); do **not** file a public issue.

## 15. Not legal advice

Nothing in this document is legal advice. The project owner is not your lawyer. A solicitor qualified in England & Wales must review this document before it is relied on for any specific legal defence or commercial relationship.
