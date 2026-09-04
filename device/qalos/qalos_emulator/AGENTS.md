# `device/qalos/qalos_emulator/` — AGENTS.md

> The qalos emulator product. Folder-scoped opinions for any LLM/agent
> working in this subtree. The **root `AGENTS.md`** and the parent
> [`device/AGENTS.md`](../../AGENTS.md) and
> [`device/qalos/AGENTS.md`](../AGENTS.md) are the single source of
> truth for cross-cutting rules. If they disagree, the root wins.

This is the only qalos product today: a thin overlay on AOSP's generic
x86_64 emulator (`aosp_x86_64.mk`) that re-brands the image, sets a
qalos-specific build id, includes the first-party qalos apps, and wires
a small vendor SELinux overlay for the Remote Control Service.

## What's in this folder

```
qalos_emulator/
├── AndroidProducts.mk          ← registers the product for `lunch`
├── BoardConfig.mk              ← board + BOARD_SEPOLICY_DIRS
├── device.mk                   ← product additions: packages, properties
├── qalos_emulator.mk           ← product definition: name, branding, build id
└── sepolicy/                   ← vendor SELinux overlay (see its AGENTS.md)
```

The four `*.mk` files are the contract the AOSP build system looks for
by name. Do not rename or merge them.

## Opinions (product-wide)

### File roles

1. **`AndroidProducts.mk` is the registration file.** It exposes the
   product to `lunch`. Add a new line to `PRODUCT_MAKEFILES` only when
   introducing a sibling product makefile (e.g. `qalos_emulator_debug.mk`).
   Do not put product logic here.
2. **`qalos_emulator.mk` is the product definition.** This is where
   `PRODUCT_NAME`, `PRODUCT_DEVICE`, branding, and `BUILD_ID` live.
   It also calls `inherit-product` to pull in the AOSP base + `device.mk`.
3. **`BoardConfig.mk` is board-level config.** It includes
   `device/generic/x86_64/BoardConfig.mk` and sets
   `BOARD_SEPOLICY_DIRS`. **No product properties, no `PRODUCT_PACKAGES`**
   in this file — those belong in `device.mk`.
4. **`device.mk` is product-level additions.** It adds packages
   (`PRODUCT_PACKAGES`) and product-wide property overrides
   (`PRODUCT_PROPERTY_OVERRIDES`). It must not do another
   `inherit-product` for `device/generic/x86_64/` — AOSP's
   `device/generic/x86_64/` tree in `android-15.0.0_r1` has no
   `device.mk`; any such inherit aborts the build with
   `error: device/generic/x86_64/device.mk does not exist.`

### AOSP-specific rules (these are non-obvious — read once, never trip on them)

5. **`BOARD_SEPOLICY_DIRS` must be set in `BoardConfig.mk`.** Setting it
   in `device.mk` is **silently ignored** on AOSP 14+/15+ for vendor
   policy. The SELinux overlay is wired from `BoardConfig.mk`, not from
   `device.mk`. See the rationale comment in `BoardConfig.mk`.
6. **Do not invent new `inherit-product` chains to `device/generic/x86_64/`.**
   The only valid base for this product is
   `$(SRC_TARGET_DIR)/product/aosp_x86_64.mk`, already inherited in
   `qalos_emulator.mk`. Anything else fights the AOSP build system.
7. **`PRODUCT_PROPERTY_OVERRIDES` is deprecated** in favour of the
   partition-specific `PRODUCT_<PARTITION>_PROPERTIES` lists
   (see `core/product.mk` TODO(b/117892318)). v0 keeps the deprecated
   form because the system-visible build-id properties are exactly
   what the AOSP compat layer still wires correctly. Switching to
   `PRODUCT_SYSTEM_PROPERTIES` is a deliberate v1 change, not a drive-by.

### qalos-specific rules (read these before editing branding/build id)

8. **Branding strings are owner-controlled.**
   `PRODUCT_BRAND = QA Lab`, `PRODUCT_MODEL = QA Lab Operating System`,
   `PRODUCT_MANUFACTURER = QA Lab`. Do not change without explicit owner
   sign-off. These end up in `ro.product.*` and the AVD boot screen.
9. **Build id format is `QAL.<YYYYMMDD>.NNN`.** The date stamp is
   `$(shell date -u +%Y%m%d)`; the patch digit (`.NNN`) is the human
   signal for the Nth build on a given date. Bump it for hot-fix builds
   on the same day. Do not change the format.
10. **`BUILD_VERSION_TAGS = qalos`.** This is the string AOSP uses to
    distinguish qalos builds from upstream AOSP. Keep it.

## Out of scope here

- **SELinux rule content** → [`sepolicy/AGENTS.md`](sepolicy/AGENTS.md)
- **Apps included via `PRODUCT_PACKAGES`** → `packages/apps/QaLab/`, `packages/apps/RemoteControlService/`
- **The kernel** — inherited from AOSP's `device/generic/x86_64/` via
  `BoardConfig.mk`. To change the kernel config, override
  `TARGET_KERNEL_CONFIG` in `BoardConfig.mk`.
- **Cloud build orchestration** → `tools/`, `scripts/`, and the root AGENTS.md

## When to add a new file here

- New build-time tunables for this product → `BoardConfig.mk`
- New packages, properties, or init hooks → `device.mk`
- New branding strings, build id format, or product-level metadata → `qalos_emulator.mk`
- A second product variant (e.g. `qalos_emulator_debug`) → its own `<variant>.mk`
  registered in `AndroidProducts.mk`

Do not add a new file to this folder unless it fits one of those buckets.
If you find yourself wanting to add a `sepolicy_overlay.mk` or
`packages_manifest.mk`, that is a sign the new file belongs in its own
subfolder with its own `AGENTS.md`.

## Related

- [`../../../AGENTS.md`](../../../AGENTS.md) — root
- [`../../AGENTS.md`](../../AGENTS.md) — `device/` entry point
- [`../AGENTS.md`](../AGENTS.md) — vendor root
- [`sepolicy/AGENTS.md`](sepolicy/AGENTS.md) — SELinux overlay
