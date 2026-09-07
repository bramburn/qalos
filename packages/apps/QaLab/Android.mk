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
# LOCAL_PRIVATE_PLATFORM_APIS := true links this package against the
# platform android.jar (same effect as LOCAL_SDK_VERSION := current)
# so we can sign it with the platform key. The QaLab activity itself
# only uses public SDK APIs -- @hide access is not currently needed.
# Keep the line anyway; if a future revision uses @hide APIs (e.g.
# for system_server integration), no Android.mk change is required.
LOCAL_PRIVATE_PLATFORM_APIS := true

include $(BUILD_PACKAGE)
