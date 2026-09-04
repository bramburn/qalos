# `device/` — AGENTS.md

> Folder-scoped opinions for any LLM/agent working in this subtree.
> The **root `AGENTS.md`** is the single source of truth for cross-cutting
> rules (build paths, cost, safety nets, CI). If the two disagree, the root wins.

This is the standard AOSP `device/` tree. qalos follows the AOSP convention:
`device/<vendor>/<product>/` for the SoC board + product makefiles, with
optional subfolders (`sepolicy/`, `kernel/`, `bootloader/`, `init/`, etc.)
for the device-specific overlays.

## What's in this folder

```
device/
└── qalos/
    ├── qalos_emulator/      ← the only qalos product (x86_64 emulator)
    │   ├── sepolicy/        ← vendor SELinux overlay
    │   ├── AndroidProducts.mk
    │   ├── BoardConfig.mk
    │   ├── device.mk
    │   └── qalos_emulator.mk
    └── (future)             ← one subfolder per new qalos product
```

## Opinions (folder-wide)

1. **`device/` is for DEVICE-LEVEL additions only.** Kernel config, HAL
   hooks, init rc fragments, SELinux overlays, and product branding live
   here. **User-space apps do NOT belong here** — those go in
   `packages/apps/`. If you find yourself adding an APK in this tree,
   you are in the wrong folder.
2. **Vendor subfolder = one per vendor.** Currently `qalos/`. Add a
   sibling only when introducing a new vendor (e.g. `partner/`, `google/`
   for an SoC drop). Do not nest vendors.
3. **Product subfolder = one per shippable product.** Today that is
   `qalos_emulator/`. Future products (`qalos_rpi5`, `qalos_tegra`,
   etc.) live as siblings of `qalos_emulator/` under the same vendor.
4. **`AGENTS.md` placement follows structural boundaries, not every
   leaf.** Add a nested `AGENTS.md` at vendor root, product root, and
   at each meaningful subfolder (e.g. `sepolicy/`, `kernel/`). Do not
   create one for every file.
5. **AOSP file naming is sacred.** `AndroidProducts.mk`, `BoardConfig.mk`,
   `device.mk`, and `<product>.mk` are what the AOSP build system looks
   for by name. Do not rename them.

## Out of scope here

- **Apps** → `packages/apps/QaLab/`, `packages/apps/RemoteControlService/`
- **Kernel sources** → resolved by the manifest (`default.xml`); not in this repo
- **Build orchestration** → `tools/` (on-host scripts) and `scripts/` (cloud twins)
- **Manifest** → `default.xml` at repo root

## When to add another nested `AGENTS.md`

Add a new `AGENTS.md` directly under a subfolder when **all** of these hold:

- The subfolder has more than one file or is a non-trivial leaf group.
- The subfolder has folder-specific rules that would be noise at the parent level
  (e.g. "never relax `neverallow` rules" for `sepolicy/`).
- You find yourself repeating the same guidance in two PRs in a row.

Do **not** add one for a single file with no children, just for the sake of
"completeness". That is documentation theater.

## Related

- [`../AGENTS.md`](../../AGENTS.md) — root: repo-wide architecture, build paths, safety nets
- [`qalos/AGENTS.md`](qalos/AGENTS.md) — vendor root
- [`qalos/qalos_emulator/AGENTS.md`](qalos/qalos_emulator/AGENTS.md) — the product
- [`qalos/qalos_emulator/sepolicy/AGENTS.md`](qalos/qalos_emulator/sepolicy/AGENTS.md) — SELinux overlay
