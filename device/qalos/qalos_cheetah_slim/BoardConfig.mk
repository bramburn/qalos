# BoardConfig.mk for qalos_cheetah_slim.
#
# Slim is the SAME physical device (Pixel 7 Pro / cheetah) as
# qalos_cheetah — only the package set differs — so it reuses the vanilla
# board config, which itself layers on the vendored Google tree.
#
# This file exists only because AOSP 15 discovers BoardConfig.mk by
# searching device/ and vendor/ for '*/$(TARGET_DEVICE)/BoardConfig.mk'
# (build/make/core/board_config.mk): the slim product has its own
# TARGET_DEVICE (qalos_cheetah_slim), so without this file lunch fails
# with "No config file found for TARGET_DEVICE qalos_cheetah_slim".
include device/qalos/qalos_cheetah/BoardConfig.mk
