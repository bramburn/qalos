// SPDX-License-Identifier: Apache-2.0
/*
 * qalos — Remote Control Service internal interface.
 *
 * v0 is same-process only: the HttpApiServer (also in system_server)
 * calls these methods directly on the service instance. There is no
 * AIDL Binder publication in v0; the only external surface is the
 * HTTP/JSON API on 127.0.0.1:9000.
 *
 * Why not AIDL? The services.core-sources filegroup globs every
 * .java file under java/ but does not match .aidl files. The
 * standard AOSP pattern is to put AIDL in core/java/android/<pkg>/
 * and declare it in frameworks/base/Android.bp's aidl_interface
 * block. For v0, with no privileged client binding to the service
 * over Binder, the plain Java interface is the right shape. A v1+
 * that wants Binder can re-introduce the AIDL by moving it to
 * core/java/android/os/ and patching frameworks/base/Android.bp.
 *
 * The interface is in the com.qalos.remotectl package on purpose:
 * the service and the HTTP server are both in this package, and
 * the interface is a private contract between them.
 */
package com.qalos.remotectl;

import android.util.Size;

/**
 * Service-side metadata. Returned by {@link IRemoteControl#getServiceInfo()}.
 * Plain-old Java class with public final fields so the HTTP layer can
 * serialize it without a JSON library.
 */
final class ServiceInfo {
    public final String serviceVersion;
    public final int apiVersion;
    public final String buildId;
    public final long startedAtEpochMs;
    public final int uptimeMs;

    ServiceInfo(String serviceVersion, int apiVersion, String buildId,
                long startedAtEpochMs, int uptimeMs) {
        this.serviceVersion = serviceVersion;
        this.apiVersion = apiVersion;
        this.buildId = buildId;
        this.startedAtEpochMs = startedAtEpochMs;
        this.uptimeMs = uptimeMs;
    }
}

/**
 * Screenshot payload with effective dimensions. Returned by
 * {@link IRemoteControl#screenshotBase64}. The base64 string is the
 * PNG bytes; the width/height are the dimensions the bitmap was
 * actually encoded at (not necessarily the requested ones — passing
 * 0 means "native display size" and the result reflects that).
 */
final class ScreenshotResult {
    public final String base64;
    public final int width;
    public final int height;

    ScreenshotResult(String base64, int width, int height) {
        this.base64 = base64;
        this.width = width;
        this.height = height;
    }
}

/**
 * Device-side metadata. Returned by {@link IRemoteControl#getDeviceInfo()}.
 */
final class DeviceInfo {
    public final String manufacturer;
    public final String model;
    public final String androidRelease;
    public final int androidSdk;
    public final int displayWidth;
    public final int displayHeight;
    public final String foregroundPackage;

    DeviceInfo(String manufacturer, String model, String androidRelease,
               int androidSdk, Size displaySize, String foregroundPackage) {
        this.manufacturer = manufacturer;
        this.model = model;
        this.androidRelease = androidRelease;
        this.androidSdk = androidSdk;
        this.displayWidth = displaySize != null ? displaySize.getWidth() : 0;
        this.displayHeight = displaySize != null ? displaySize.getHeight() : 0;
        this.foregroundPackage = foregroundPackage != null ? foregroundPackage : "";
    }
}

/**
 * Internal contract between {@link RemoteControlService} and
 * {@link HttpApiServer}. See the HTTP API reference for the
 * on-wire shape that each method backs.
 */
interface IRemoteControl {
    // --- Input ---
    void tap(int x, int y, int displayId);
    void typeText(String text);
    void keyEvent(int keyCode, boolean down);

    // --- Gestures (v0.1) ---
    /** Press-and-hold: ACTION_DOWN at (x, y), wait {@code durationMs}, ACTION_UP. */
    void longPress(int x, int y, int durationMs, int displayId);
    /** Linear drag from (x1, y1) to (x2, y2) over {@code durationMs}, {@code steps} intermediate MOVE events. */
    void swipe(int x1, int y1, int x2, int y2, int steps, int durationMs, int displayId);
    /** Two-finger zoom centered at (cx, cy), radius interpolating from r1 to r2 over {@code durationMs}. */
    void pinch(int cx, int cy, int r1, int r2, int steps, int durationMs, int displayId);

    // --- App lifecycle ---
    void launchApp(String packageName);
    void forceStop(String packageName);

    // --- Queries ---
    String getForegroundPackage();
    int getDisplayWidth(int displayId);
    int getDisplayHeight(int displayId);

    // --- Screenshot (returns a base64-encoded PNG so the HTTP layer
    //     does not need to encode it again). The result includes the
    //     *effective* capture dimensions, which may differ from the
    //     requested (width, height) when the caller passed 0. v0.1.1
    //     review-triage: the HTTP layer echoes these back to the
    //     client so a `?width=0&height=0` request returns native
    //     display dimensions, not 0. ---
    ScreenshotResult screenshotBase64(int width, int height, int displayId, int quality);

    // --- Service / device metadata (v0.1) ---
    ServiceInfo getServiceInfo();
    DeviceInfo getDeviceInfo();
}
