# device/google/cheetah-kernels — Pixel 7 Pro kernel (VENDORED STUB)

Pixel device trees often keep the kernel in a separate `*-kernels` repo.
For cheetah (Pixel 7 Pro), the kernel is Linux 5.10 with Google-specific
patches (GS201 SoC / Tensor G2).

## How to populate

```bash
cd /home/bramburn/aosp
git clone https://github.com/nickel-jn/cheetah-kernels \
    device/google/cheetah-kernels
# OR
git clone https://github.com/LineageOS/android_kernel_google_gs201 \
    device/google/cheetah-kernels
```

## Build verification

After populating:
```bash
lunch qalos_cheetah-userdebug
m -j4 kernel
```

Should produce `out/target/product/qalos_cheetah/obj/KERNEL_OBJ/arch/arm64/boot/Image.lz4`
(`TARGET_DEVICE` is `qalos_cheetah`, not `cheetah` — see
`device/google/cheetah/README.md` "How the qalos layer is wired")
and the device-specific `kernel` target should compile.
