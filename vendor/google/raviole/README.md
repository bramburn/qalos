# vendor/google/raviole — Pixel 6 family platform, NOT needed for cheetah (DOCS ONLY)

`raviole` is the GS101 (Tensor G1) platform shared by Pixel 6 / 6 Pro /
6a. The Pixel 7 Pro (cheetah) is the **GS201 / pantah** platform — its
shared blobs live under `vendor/google_devices/gs201/`, not here.

This directory is the legacy (AOSP ≤ 13-era) vendor path and is **not
referenced by any AOSP 15 cheetah makefile**. It is kept only as a
documentation anchor. If you are building the Pixel 6 instead, its public
device tree (`device/google/raviole`, in `upstream.xml`) references
`vendor/google_devices/raviole/` the same way pantah references
`vendor/google_devices/pantah/`.

Historical note: an earlier version of this README claimed Pixel 7 Pro
"inherits the raviole platform" — that is wrong; Pixel 7 Pro is GS201.
Verified 2026-09-25 against `android-15.0.0_r1`.
