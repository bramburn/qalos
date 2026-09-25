# vendor/aqa — Pixel 7 Pro QA build variants

Automated QA testbed images for the Pixel 7 Pro (`cheetah`, GS201/pantah
platform). Each image bundles the `aqa_server` native daemon — an HTTP/JSON
REST API plus `/dev/uinput` touch injection — so the device can be driven from
any host on the same network.

## Build variants

| Variant | Description | Use case |
| --- | --- | --- |
| `aqa_cheetah_full` | Full AOSP cheetah + aqa_server | QA against the complete app surface |
| `aqa_cheetah_slim` | Cheetah minus bloat + aqa_server | Headless phone/SMS QA rigs |
| `qalos_cheetah` | qalos-branded vanilla, no daemon | Manual user testing |
| `qalos_cheetah_slim` | qalos-branded slim, no daemon | Manual slim baseline |

Both `aqa_*` variants can be Magisk-patched after the build
(`build_ecs.sh full magisk`).

## Directory layout

```text
vendor/aqa/
├── aqa_cheetah_full/          one product per directory
│   ├── AndroidProducts.mk     product registration (lunch combos)
│   ├── BoardConfig.mk         TARGET_DEVICE_DIR board config
│   ├── device.mk              layered device additions (NOT auto-loaded)
│   └── aqa_cheetah_full.mk    the product makefile
├── aqa_cheetah_slim/          same four files
├── server/                    aqa_server daemon
│   ├── Android.bp             Soong config (no `vendor: true` → /system/bin)
│   ├── aqa_server.rc          init fragment: class=main, user=root, seclabel=su
│   ├── README.md              endpoint reference + security notes
│   └── src/
│       ├── main.cpp                 REST routing, JSON scan, shell-outs
│       ├── http_server.{hpp,cpp}    dependency-free HTTP/1.1 server
│       └── uinput_injector.{hpp,cpp} /dev/uinput touch + key injection
└── scripts/
    └── build_ecs.sh           build orchestrator (full | slim [+ magisk])
```

## Why each product is its own directory

AOSP 15 discovers build inputs by globbing exactly two levels below the
partition root:

```text
device/*/*/AndroidProducts.mk        vendor/*/*/AndroidProducts.mk
device/*/$(TARGET_DEVICE)/BoardConfig.mk
vendor/*/$(TARGET_DEVICE)/BoardConfig.mk
```

So `vendor/aqa/aqa_cheetah_full/` has to be the product directory — a
`vendor/aqa/products/<name>.mk` layout is invisible to the build. For the same
reason `PRODUCT_DEVICE` must equal the directory name: with
`PRODUCT_DEVICE := cheetah` the board-config search matches AOSP's own
`device/google/pantah/cheetah/BoardConfig.mk` and this entire layer is
silently skipped.

## Prerequisite: apply-qalos.sh

The qalos repo *is* the manifest, so it is checked out at `.repo/manifests/`
and nothing under it exists in the AOSP working tree until copied. Run:

```bash
./tools/apply-qalos.sh
```

before lunching. It copies `vendor/aqa/`, `device/qalos/qalos_cheetah/` and
`device/qalos/qalos_cheetah_slim/` into place. Without it, `lunch` reports
"unknown product".

## Build

```bash
cd /home/admin/aosp
./tools/apply-qalos.sh
bash vendor/aqa/scripts/build_ecs.sh full     # or: slim  |  full magisk
```

Outputs land in `out/target/product/aqa_cheetah_<full|slim>/`.

## Security

`aqa_server` runs as **root** under `seclabel u:r:su:s0`, with **no
authentication**, and can launch/force-stop arbitrary packages and read the
SMS inbox. QA images also set `androidboot.selinux=permissive`.

This is intentional for a private test network and is **not shippable in a
production image**. Restrict with iptables or keep the device on an isolated
VLAN. See `server/README.md`.