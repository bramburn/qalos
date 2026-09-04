# `device/qalos/qalos_emulator/sepolicy/` — AGENTS.md

> Vendor SELinux policy overlay for the qalos emulator product. Folder-scoped
> opinions for any LLM/agent working in this subtree. The **root `AGENTS.md`**
> and the parent product [`AGENTS.md`](../AGENTS.md) are the single source
> of truth for cross-cutting rules. If they disagree, the root wins.

This is a **vendor SELinux overlay**. It is wired into the AOSP sepolicy
build via `BOARD_SEPOLICY_DIRS` in
[`../BoardConfig.mk`](../BoardConfig.mk) — see the rationale comment there
for why `BOARD_SEPOLICY_DIRS` must be set in `BoardConfig.mk` and not in
`device.mk`.

## What's in this folder

```
sepolicy/
├── qalos_remote_control.te    ← type definition for the new service
├── service_contexts           ← file-context label for the service binary
└── system_server.te           ← allow rules appended to upstream
```

The AOSP sepolicy build concatenates every directory listed in
`BOARD_SEPOLICY_DIRS` with the upstream system policy. **Rules here are
appended to (not replacing) the upstream AOSP system_server.te.**

## Opinions (folder-wide — read before editing any `.te` file)

1. **Append, never replace.** These files extend upstream AOSP policy.
   They are merged into the system policy at build time. If you find
   yourself wanting to redefine an upstream type, stop — that is the
   wrong layer. Push the change upstream or use a different type.
2. **Never relax `neverallow` rules.** Adding `allow` rules is fine.
   Removing or weakening an upstream `neverallow` is not. If a
   `neverallow` blocks a legitimate qalos need, the right answer is a
   new properly-typed domain for the qalos service (see rule 3), not
   a weakening of policy.
3. **Follow the upstream domain convention.** AOSP services that bind
   TCP sockets (e.g. `audioserver`, `mediaserver`) have their own
   SELinux domains. `system_server` is not a general-purpose TCP-bind
   domain. For v0, the qalos Remote Control Service binds a TCP socket
   *from inside* `system_server` (no AIDL, no Binder publication), so
   the allow rule grants `system_server` permissions on its own
   `self:tcp_socket` — mirroring what the upstream services do.
   For v1+ AIDL re-introduction, the service gets its own domain
   (the `qalos_remote_control` type) with explicit allow rules from
   the calling app domain.
4. **Never use permissive domains.** If you cannot get an `allow` rule
   to work, that is a design signal — the service architecture is
   wrong, not the policy. Permissive domains are debugging tools,
   not a production posture, and they are not accepted in this repo.
5. **File layout follows AOSP convention.**
   - New **type definition** → `<service>.te`
     (e.g. `qalos_remote_control.te`)
   - **File-context label** for the service binary → `service_contexts`
     (one `<binary> u:object_r:<type>:s0` line)
   - **Allow rules** for an existing domain → `<calling_domain>.te`
     (e.g. `system_server.te` for rules granted to `system_server`)
   Do not invent a new layout. The AOSP build system reads by filename.

## When AOSP rebases

`BoardConfig.mk` references
`packages/apps/RemoteControlService/REBASE.md`. That document is the
authoritative procedure for updating this overlay when upstream AOSP
changes its system_server policy or its type definitions for the
services we extend. Read it before rebase work; do not improvise
SELinux changes across rebase boundaries.

## Out of scope here

- **Adding apps or binaries** — this folder only carries `.te` rules
  and the `service_contexts` file. The binaries themselves live in
  `packages/apps/RemoteControlService/` and the AOSP build pulls them
  in via `PRODUCT_PACKAGES` in the parent folder's `device.mk`.
- **Modifying upstream AOSP policy** — this is an overlay only. To
  change an upstream rule, the change belongs upstream.
- **macros / MLS / userspace SELinux APIs** — not used in v0.

## Audit checklist (use before opening a PR that touches this folder)

- [ ] Did you add an `allow` rule that crosses a type boundary
      previously protected by an upstream `neverallow`? If yes,
      reject the change and redesign the domain instead.
- [ ] Did you add a new `<service>.te`? If yes, the matching line in
      `service_contexts` and the calling-domain's `<domain>.te` must
      be in the same PR.
- [ ] Did you add a new binary path? If yes, the matching
      `file_contexts` entry (and any new `genfscon`) is in the same PR.
- [ ] Did the change touch a file that AOSP's policy build concatenates
      with upstream? If yes, run the policy build (`m selinux_policy`
      or the relevant target) locally before pushing.

## Related

- [`../../../../AGENTS.md`](../../../../AGENTS.md) — root
- [`../../../AGENTS.md`](../../../AGENTS.md) — `device/` entry point
- [`../../AGENTS.md`](../../AGENTS.md) — vendor root
- [`../AGENTS.md`](../AGENTS.md) — the product
- `packages/apps/RemoteControlService/REBASE.md` — rebase procedure
  (referenced from `../BoardConfig.mk`)
