# Registers the qalos products defined in this directory with the AOSP build system.
# `lunch` reads this file to populate its target list.
#
# AOSP 15's `lunch` requires the 3-part format `<product>-<release>-<variant>`
# (see build/make/envsetup.sh:442 function lunch). The 2-part form is rejected
# with "Invalid lunch combo: <combo> / Valid combos must be of the form
# <product>-<release>-<variant>". We use `trunk_staging` for the release label
# (matches the AOSP-15 default prompt; the value is a free-form string used in
# BUILD_ID-style metadata, not a tag or branch).
#
# do-build.sh and any human invocation must use one of the combos below
# verbatim, e.g. `lunch qalos_emulator-trunk_staging-userdebug`.

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/qalos_emulator.mk

COMMON_LUNCH_CHOICES := \
    qalos_emulator-trunk_staging-userdebug \
    qalos_emulator-trunk_staging-eng \
    qalos_emulator-trunk_staging-user
