# device/google/cheetah-kernels — Pixel 7 Pro kernel docs anchor

**Nothing to clone here.** The Pixel 7 Pro (cheetah) kernel is Linux 5.10
with Google-specific patches (GS201 SoC / Tensor G2), and AOSP 15 ships
the prebuilt kernel in the public manifest: `repo sync` fetches
`device/google/pantah-kernels/5.10/` (see `upstream.xml`).

The build selects it via `TARGET_LINUX_KERNEL_VERSION := 5.10` and the
`RELEASE_KERNEL_CHEETAH_*` variables in
`device/google/pantah/device-cheetah.mk`.

## Build verification

After syncing:

```bash
lunch qalos_cheetah-userdebug
m -j4 kernel
```

Should produce
`out/target/product/qalos_cheetah/obj/KERNEL_OBJ/arch/arm64/boot/Image.lz4`
(`TARGET_DEVICE` is `qalos_cheetah`, not `cheetah` — see
`device/google/cheetah/README.md` "How the qalos layer is wired")
and the device-specific `kernel` target should compile.

## Custom kernels

Only if you want to build the kernel from source (not needed for QA
images) fork the AOSP kernel tree:
`https://android.googlesource.com/kernel/devices/google/pantah` is not
public; community mirrors live under LineageOS
(`android_kernel_google_gs201`, referenced by
`android_device_google_pantah/lineage.dependencies`).
