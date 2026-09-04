# `device/qalos/` — AGENTS.md

> Vendor root for qalos. Folder-scoped opinions for any LLM/agent working
> in this subtree. The **root `AGENTS.md`** and [`../AGENTS.md`](../../AGENTS.md)
> are the single source of truth for cross-cutting rules. If they disagree,
> the root wins.

This is the qalos vendor directory. Every qalos shippable product lives
as a child subfolder.

## What's in this folder

```
device/qalos/
└── qalos_emulator/      ← only qalos product today (x86_64 AOSP emulator)
    └── sepolicy/        ← vendor SELinux overlay for that product
```

## Opinions (folder-wide)

1. **One product per subfolder.** Each child of `device/qalos/` is a
   single, shippable qalos product with its own `AndroidProducts.mk`,
   `BoardConfig.mk`, `device.mk`, and `<product>.mk`. Do not co-locate
   two products under one folder.
2. **v0 is x86_64-only.** The only currently shipping target is the AOSP
   generic x86_64 emulator, inherited via
   `$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_x86_64.mk)`.
   Do **not** add arm64/aarch64 or RISC-V targets here in v0 without
   an owner-approved RFC — see root AGENTS.md §8 (known limitations).
3. **The vendor folder stays thin.** No first-party qalos code (apps,
   daemons, init rc) lives directly in `device/qalos/`. Only product
   subfolders and their subfolders.
4. **`BOARD_SEPOLICY_DIRS` belongs in the product's `BoardConfig.mk`,
   not in `device.mk`.** AOSP 14+/15+ silently ignores it in `device.mk`
   for vendor policy. See
   [`qalos_emulator/BoardConfig.mk`](qalos_emulator/BoardConfig.mk)
   and the rationale comment there.
5. **Don't fork AOSP's `device/generic/x86_64/` content into this folder.**
   qalos is a thin overlay. Inherit from upstream; override only what
   qalos must change (branding, build id, package list, sepolicy).

## Out of scope here

- **Apps** → `packages/apps/QaLab/`, `packages/apps/RemoteControlService/`
- **Detailed makefile content per product** → that product's own `AGENTS.md`
- **SELinux rules** → [`qalos_emulator/sepolicy/AGENTS.md`](qalos_emulator/sepolicy/AGENTS.md)
- **Build / cloud orchestration** → `tools/` + `scripts/` (and the root AGENTS.md)

## When to add a new child subfolder here

Add a new product subfolder (e.g. `qalos_rpi5/`, `qalos_tegra/`) only when
**all** of these hold:

- There is a real, non-emulator target the QA Lab actually needs.
- AOSP already provides a base product to inherit from (e.g.
  `aosp_rpi5.mk` for Raspberry Pi 5). Do not build a board from scratch
  in this repo.
- The build path, on-host script, and CI implications have been thought
  through. See root AGENTS.md §5 (workflows) and §2.5 (provider is a
  parameter, not a hard-coded choice).

Until then, this folder holds exactly one product.

## Related

- [`../../AGENTS.md`](../../AGENTS.md) — root: architecture, build paths, safety nets
- [`../AGENTS.md`](../AGENTS.md) — `device/` entry point
- [`qalos_emulator/AGENTS.md`](qalos_emulator/AGENTS.md) — the only qalos product today
