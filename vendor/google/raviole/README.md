# vendor/google/raviole — shared Pixel 6/7/7 Pro blobs (VENDORED STUB)

Pixel 6, 6 Pro, 6a, 7, 7 Pro, and 7a all share the same SoC platform
(GS201 / Tensor G2). The shared platform blobs live here. Cheetah
(Pixel 7 Pro) inherits the raviole platform.

## How to populate

Same as `vendor/google/cheetah/`:

```bash
cd /home/bramburn/aosp
cd device/google/cheetah
./extract-files.sh
```

The script populates BOTH `vendor/google/cheetah/` (device-specific) and
`vendor/google/raviole/` (shared platform) from the Google binary
distribution.
