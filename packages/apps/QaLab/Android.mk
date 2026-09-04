LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)

LOCAL_MODULE_TAGS := optional
# LOCAL_MODULE is forbidden in AOSP 15 package modules (enforced by
# build/make/core/package_internal.mk:43). The package name is auto-derived
# from the directory name; use LOCAL_PACKAGE_NAME below for any explicit
# override.
LOCAL_SRC_FILES := $(call all-java-files-under, src)
LOCAL_PACKAGE_NAME := QaLab
LOCAL_CERTIFICATE := platform
# AOSP 15 requires every package to declare either LOCAL_SDK_VERSION (which
# SDK level the package targets) or LOCAL_PRIVATE_PLATFORM_APIS (true for
# platform-signed apps that use @hide APIs). QaLab is platform-signed and
# uses @hide system_server APIs (e.g. ActivityManager.getRecentTasks), so
# declare LOCAL_PRIVATE_PLATFORM_APIS.
LOCAL_PRIVATE_PLATFORM_APIS := true

include $(BUILD_PACKAGE)
