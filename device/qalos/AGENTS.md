# `device/qalos/` — AGENTS.md

> Vendor root for qalos. Folder-scoped opinions for any LLM/agent working
> in this subtree. The **root `AGENTS.md`** and [`../AGENTS.md`](../AGENTS.md)
> are the single source of truth for cross-cutting rules. If they disagree,
> the root wins.

This is the qalos vendor directory. Every qalos shippable product lives
as a child subfolder.

## What's in this folder

```text
device/qalos/
├── qalos_emulator/        ← x86_64 AOSP emulator (the original v0 target)
│   └── sepolicy/          ← vendor SELinux overlay for that product
├── qalos_cheetah/         ← Pixel 7 Pro (vanilla qalos build)
├── qalos_cheetah_slim/    ← Pixel 7 Pro, stripped package set
├── gms/                   ← GMS-mimic stubs (not a product)
└── patches/               ← framework patch payloads (not a product)
```

The AQA variants (Pixel 7 Pro **plus** the `aqa_server` automation daemon)
live under `vendor/aqa/`, not here, because they are a QA-testbed layer
rather than qalos branding — see [`../../vendor/aqa/README.md`](../../vendor/aqa/README.md).

## Opinions (folder-wide)

1. **One product per subfolder.** Each child of `device/qalos/` is a
   single, shippable qalos product with its own `AndroidProducts.mk`,
   `BoardConfig.mk`, `device.mk`, and `<product>.mk`. Do not co-locate
   two products under one folder.

2. **`PRODUCT_DEVICE` must equal the product directory name.** AOSP 15
   resolves `TARGET_DEVICE_DIR` by globbing `device/*/$(TARGET_DEVICE)/
   BoardConfig.mk` and `vendor/*/$(TARGET_DEVICE)/BoardConfig.mk`
   (`build/make/core/board_config.mk`). If `PRODUCT_DEVICE` is a bare device
   codename (e.g. `cheetah`), the glob matches AOSP's own
   `device/google/pantah/cheetah/BoardConfig.mk` and the qalos layer is
   silently skipped. It also gives each product its own `PRODUCT_OUT`
   (`out/target/product/<product>`), so variants never overwrite each other.

3. **Products stay exactly two levels below the partition root** —
   `device/*/*/AndroidProducts.mk` is the discovery glob
   (`build/make/core/product_config.mk`). A `device/qalos/products/<x>.mk`
   layout is invisible to the build.

4. **The vendor folder stays thin.** No first-party qalos code (apps,
   daemons, init rc) lives directly in `device/qalos/`. Only product
   subfolders and their subfolders.

5. **`BOARD_VENDOR_SEPOLICY_DIRS` belongs in the product's `BoardConfig.mk`,
   not in `device.mk`.** AOSP 14+/15+ silently ignores it in `device.mk`
   for vendor policy. See
   [`qalos_emulator/BoardConfig.mk`](qalos_emulator/BoardConfig.mk)
   and the rationale comment there.

6. **Don't fork AOSP's `device/generic/x86_64/` or `device/google/pantah/`
   content into this folder.** qalos is a thin overlay. Inherit from
   upstream; override only what qalos must change (branding, build id,
   package list, sepolicy).

7. **Never override `BUILD_FINGERPRINT`.** AOSP computes it from the brand,
   product, device and the *actual* lunch variant
   (`build/make/core/sysprop.mk`). A hardcoded `userdebug/test-keys` literal
   breaks `-user`/`-eng` builds and desyncs `ro.product.*`. Same for
   `TARGET_BUILD_VARIANT` in a `BoardConfig.mk`.

8. **`device.mk` is not auto-loaded.** Nothing in `build/make/core` references
   it; it only takes effect because the product `.mk` inherits it explicitly.
   Omitting the inherit silently drops every setting in it.

9. **Don't add a `PRODUCT_PACKAGES` entry for a module that doesn't exist.**
   An unknown name aborts the build. `AuditLogger`, for example, is not a real
   module — audit capture comes from `RemoteControlService`, which
   `tools/apply-qalos.sh` patches into `frameworks/base`.

## Out of scope here

- **Apps** → `packages/apps/QaLab/`, `packages/apps/RemoteControlService/`

- **AQA testbed products + daemon** → `vendor/aqa/`

- **Detailed makefile content per product** → that product's own `AGENTS.md`

- **SELinux rules** → [`qalos_emulator/sepolicy/AGENTS.md`](qalos_emulator/sepolicy/AGENTS.md)

- **Build / cloud orchestration** → `tools/` + `scripts/` (and the root AGENTS.md)

## Wiring into the AOSP tree

The qalos repo **is** the manifest, so it is checked out at
`.repo/manifests/` — nothing under `device/qalos/` exists in the AOSP working
tree until `tools/apply-qalos.sh` copies it. **Any new product directory must
be added to the `copy_path` list in that script**, or `lunch` reports
"unknown product". Both cheetah products and `vendor/aqa/` are registered
there.

## When to add a new child subfolder here

Add a new product subfolder only when **all** of these hold:

- There is a real target the QA Lab actually needs.

- AOSP already provides a base product to inherit from (e.g.
  `aosp_cheetah.mk` for Pixel 7 Pro). Do not build a board from scratch
  in this repo.

- The copy step in `tools/apply-qalos.sh` is updated, and the build path,
  on-host script and CI implications have been thought through. See root
  AGENTS.md §5 (workflows) and §2.5 (provider is a parameter, not a
  hard-coded choice).

## Related

- [`../../AGENTS.md`](../../AGENTS.md) — root: architecture, build paths, safety nets

- [`../AGENTS.md`](../AGENTS.md) — `device/` entry point

- [`qalos_emulator/AGENTS.md`](qalos_emulator/AGENTS.md) — the x86_64 emulator product

- [`../../vendor/aqa/README.md`](../../vendor/aqa/README.md) — AQA testbed products
