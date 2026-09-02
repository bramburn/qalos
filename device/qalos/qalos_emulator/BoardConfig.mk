# Board config for the qalos x86_64 emulator build.
# Inherits everything from the AOSP generic x86_64 emulator board.

-include device/generic/x86_64/BoardConfig.mk

# qalos-specific build-time tunables go here. Examples:
#   TARGET_KERNEL_CONFIG := qalos_defconfig
#   BOARD_KERNEL_CMDLINE += androidboot.qalos=1
# (left empty for the first build — add knobs here as the fork matures)
