# Legal

This directory contains the legal framework for the **qalos** project (also marketed as **QA Lab Operating System**).
It is intended to protect:

- **Bhavesh Ramburn** (the natural person, GitHub handle `bramburn`) — the project's sole developer and primary maintainer.
- **Icelabz Solutions Ltd** (the company) — the entity that owns the qalos project and the trade name.
- **qalos contributors** — anyone who submits a pull request, issue, or other contribution.
- **qalos users** — anyone who downloads, builds, runs, or integrates the project.

> **DRAFT — not legal advice.** These documents were drafted from publicly available open-source templates and
> standard industry language.
> A solicitor qualified in England & Wales **must** review them before they are relied on for any specific legal
> defence or commercial relationship.
> See the "Not legal advice" note at the bottom of each document.

## Which document applies to you

| You are… | You should read… |
| --- | --- |
| A casual user who just wants to build qalos from source | [DISCLAIMER.md](DISCLAIMER.md) |
| A user who will run qalos in production or build derivative images | [DISCLAIMER.md](DISCLAIMER.md) + [TERMS_OF_SERVICE.md](TERMS_OF_SERVICE.md) + [ACCEPTABLE_USE_POLICY.md](ACCEPTABLE_USE_POLICY.md) |
| A commercial customer receiving prebuilt images, support, or hosted services | All of the above + [KYC.md](KYC.md) + [AUDIT_LOGGING.md](AUDIT_LOGGING.md) |
| A contributor submitting a PR | [CLA.md](CLA.md) + [CONTRIBUTING.md](../CONTRIBUTING.md) |
| A security researcher | [SECURITY.md](SECURITY.md) |

## The seven documents

1. **[DISCLAIMER.md](DISCLAIMER.md)** — the umbrella.
   No warranty, no liability for misuse, the project's intended use, the "no fitness for any particular purpose" carve-out.
2. **[TERMS_OF_SERVICE.md](TERMS_OF_SERVICE.md)** — the binding contract.
   What you agree to by downloading, building, or running qalos; eligibility, termination, indemnity, governing law.
3. **[ACCEPTABLE_USE_POLICY.md](ACCEPTABLE_USE_POLICY.md)** — the prohibited-uses list.
   What the OS must NOT be used for. Referenced by the ToS.
4. **[KYC.md](KYC.md)** — Know-Your-Customer for commercial users.
   Who we screen, what we collect, how long we keep it, refusal/revocation.
5. **[AUDIT_LOGGING.md](AUDIT_LOGGING.md)** — the technical + operational spec.
   If you operate a fleet of qalos devices or resell a derivative image, you MUST keep an audit log per this spec.
   This document also feeds the technical audit-log design in the `RemoteControlService` component.
6. **[CLA.md](CLA.md)** — the Contributor License Agreement.
   What you grant the project when you submit a PR, and the IP warranties you make.
7. **[SECURITY.md](SECURITY.md)** — vulnerability disclosure.
   How to report a security issue in qalos itself, our response SLA, and our safe-harbour statement.

## Document set principles

These are the non-negotiables that govern every document in this directory.
If a future change violates one, it should be a deliberate, documented exception.

1. **Jurisdiction: England & Wales.** All contracts are governed by the laws of England and Wales.
   Disputes are heard in the courts of England and Wales unless an applicable mandatory consumer-protection law says otherwise.
2. **The project is a tool, not a service.** The default qalos source distribution is provided "as is" under the MIT and Apache 2.0 licences.
   These legal docs add restrictions on USE; they do not transfer the licence.
3. **The user is responsible for the legality of their use.** Every document in this directory reaffirms this principle.
   The project is not a regulator, an auditor, or a law-enforcement agent — we provide the tool and the framework;
   the operator is accountable for what the tool is used for.
4. **KYC and audit logging are mandatory for commercial distribution.** A customer who receives a prebuilt image
   or hosted service goes through KYC and must keep an audit log.
   This is non-negotiable: the alternative is the project becoming an attractive nuisance for fraud.
5. **The DISCLAIMER is the first thing a user must see.** It is linked from the root README, the LICENSE, and the
   Docusaurus landing page. It is not buried.

## Versioning

These documents are versioned with the project.
A change to a legal document is a breaking change for users who have accepted the prior version;
a change to a legal document MUST be communicated in the release notes and, for commercial customers, by direct notice.
See [CHANGELOG.md](../CHANGELOG.md) (forthcoming) for the version history.

## Contact

- **General legal queries:** open a GitHub issue labelled `legal`.
- **Confidential legal matters** (proposed amendments, partnership, commercial licence, indemnity negotiation):
  email the maintainer at the address listed in the GitHub profile.
- **Security vulnerabilities:** follow [SECURITY.md](SECURITY.md), do **not** file a public issue.

## Not legal advice

Nothing in this directory is legal advice.
The project authors are not your lawyer.
Solicitor review is required before these documents are relied on in any specific legal context.
