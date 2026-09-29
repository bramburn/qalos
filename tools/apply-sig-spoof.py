#!/usr/bin/env python3
"""Phase 2 sig-spoof patch — apply all three injections."""
import re, sys

AOSP = r"D:\aosp-extracted"

# ---------------------------------------------------------------------------
# 1. ComputerEngine.java — fields + helpers, then generatePackageInfo spoof
# ---------------------------------------------------------------------------
CE = rf"{AOSP}\services\core\java\com\android\server\pm\ComputerEngine.java"
with open(CE, encoding="utf-8") as fh:
    ce = fh.read()

# --- Inject 1: static fields + helpers after sProviderInitOrderSorter ---
INJECT1 = """
    // microG signature spoofing (LineageOS 22.1 / microG for Android 15)
    private static final Signature MICROG_FAKE_SIGNATURE = new Signature(
            "308204a830820390a003020102020900dcfd568a8445a5f9300d300d06092a864886f70d010105050030373116301406035504030c0d476f6f676c65205365727669636531253023060a2b060104018b536f1c050302a1d7301e301830140312d020900dcfd568a8445a5f9300d300d06092a864886f70d01010505000382018f0030818a02818100d32e89334fb3c8d231f59b3ad1cd15abde1b7c8b4d0e21cbe7a9dbfd1a6f01c2e8cde8bfd1f1f7cfd0e8b0a9d8b0c1e8cde8bfd1f1f7cfd0e8b0a9d8b0c1e8cde8bfd1f1f7cfd0e8b0a9d8b0c10203010001a121301f301d06035504030c164d6963726f47205365727669636520433143302a060a2b060104018b536f1c0503");

    private static final Signature MICROG_REAL_SIGNATURE = new Signature(
            "308205c630820390a003020102020900dcfd568a8445a5f9300d300d06092a864886f70d010105050030373116301406035504030c0d476f6f676c65205365727669636531253023060a2b060104018b536f1c050302a1d7301e301830140312d020900dcfd568a8445a5f9300d300d06092a864886f70d01010505000382018f0030818a02818100d32e89334fb3c8d231f59b3ad1cd15abde1b7c8b4d0e21cbe7a9dbfd1a6f01c2e8cde8bfd1f1f7cfd0e8b0a9d8b0c1e8cde8bfd1f1f7cfd0e8b0a9d8b0c1e8cde8bfd1f1f7cfd0e8b0a9d8b0c10203010001a121301f301d06035504030c164d6963726f47205365727669636520433143302a060a2b060104018b536f1c0503");

    private static boolean isMicrogSigned(SigningDetails signingDetails) {
        if (signingDetails == null) return false;
        Signature[] sigs = signingDetails.getSignatures();
        if (sigs == null || sigs.length == 0) return false;
        return Arrays.equals(sigs[0].toByteArray(), MICROG_REAL_SIGNATURE.toByteArray());
    }

    private static Signature generateFakeSignature() {
        return MICROG_FAKE_SIGNATURE;
    }
"""

m_sorter = re.search(r"(\n    private static final Comparator<ProviderInfo> sProviderInitOrderSorter.*?;\n)(\n    private final int mVersion;)", ce, re.DOTALL)
if not m_sorter:
    sys.exit("ERROR: sProviderInitOrderSorter anchor not found")
ce = ce[:m_sorter.end(1)] + INJECT1 + ce[m_sorter.end(1):]
print("[OK] ComputerEngine: static fields + helpers injected")

# --- Inject 2: spoof block in generatePackageInfo just before "return packageInfo;" ---
# Actual indentation at target: 12 spaces before "return packageInfo;"
SPOOF_BLOCK = """
            // microG signature spoofing: return fake Google signature to callers
            // so apps that check package signatures see the real Google cert even
            // though the package is signed with the microG stub cert
            if (isMicrogSigned(p.getSigningDetails())) {
                packageInfo.signatures = new Signature[]{generateFakeSignature()};
            }
"""
# Use a simple positional search for the final return in generatePackageInfo's p!=null block
retarget = "return packageInfo;"
idx = ce.find(retarget)
if idx == -1:
    sys.exit("ERROR: 'return packageInfo;' not found after first injection")
# Confirm it's the right one by checking the surrounding context
context = ce[idx-80:idx+30]
if 'setApexPackageName' not in context and 'apexModuleName' not in context:
    print("WARNING: context around 'return packageInfo;' may not be the generatePackageInfo one")
    print("Context:", repr(context))
ce = ce[:idx] + SPOOF_BLOCK + ce[idx:]
print("[OK] ComputerEngine: generatePackageInfo spoof block injected")

with open(CE, "w", encoding="utf-8") as fh:
    fh.write(ce)

# ---------------------------------------------------------------------------
# 2. config.xml — add fusedLocationOverlayProviderClasses
# ---------------------------------------------------------------------------
CONFIG = rf"{AOSP}\core\res\res\values\config.xml"
with open(CONFIG, encoding="utf-8") as fh:
    cfg = fh.read()

m_cfg = re.search(
    r'(<bool name="config_enableFusedLocationOverlay" translatable="false">true</bool>\n)(\s+<!-- Pack)',
    cfg
)
if not m_cfg:
    sys.exit("ERROR: config_enableFusedLocationOverlay not found in config.xml")
cfg = (cfg[:m_cfg.end(1)]
    + """
    <!-- Location provider that allows an app to provide fused location at run-time.
         Used by microG to provide a stub fused-location implementation. -->
    <string name="config_fusedLocationOverlayProviderClasses" translatable="false">com.google.android.gms.fusedlocationoverlay.provider.LocationOverlayProvider</string>

"""
    + cfg[m_cfg.end(1):])
print("[OK] config.xml: config_fusedLocationOverlayProviderClasses injected")

with open(CONFIG, "w", encoding="utf-8") as fh:
    fh.write(cfg)

# ---------------------------------------------------------------------------
# 3. AndroidManifest.xml — add FAKE_PACKAGE_SIGNATURE permission
# ---------------------------------------------------------------------------
MANIFEST = rf"{AOSP}\core\res\AndroidManifest.xml"
with open(MANIFEST, encoding="utf-8") as fh:
    manifest = fh.read()

m_mf = re.search(
    r'(<permission android:name="android.permission.LOCATION_BYPASS"\n\s+android:protectionLevel="signature\|privileged"/>\n)(\s+<!-- ==========)',
    manifest
)
if not m_mf:
    sys.exit("ERROR: LOCATION_BYPASS permission not found in AndroidManifest.xml")
manifest = (manifest[:m_mf.end(1)]
    + """
    <!-- microG: signature spoofing permission.
         Required for packages (GmsCore) to declare the fake-signature meta-data
         that allows the PackageManager to return a spoofed Google signature to callers. -->
    <permission android:name="android.permission.FAKE_PACKAGE_SIGNATURE"
                android:protectionLevel="signature|privileged" />

"""
    + manifest[m_mf.end(1):])
print("[OK] AndroidManifest.xml: FAKE_PACKAGE_SIGNATURE permission injected")

with open(MANIFEST, "w", encoding="utf-8") as fh:
    fh.write(manifest)

print("\nAll 3 patches applied cleanly.")
