// SPDX-License-Identifier: Apache-2.0
/*
 * qalos — Remote Control Service.
 *
 * System service that runs inside system_server. The HttpApiServer
 * (same process) drives the service through a plain Java interface,
 * IRemoteControl. There is no AIDL Binder publication in v0; the
 * only external surface is the HTTP/JSON API on 127.0.0.1:9000,
 * tunneled out via `adb forward` for the auth boundary.
 *
 * Threading: the service is instantiated on the system_server main
 * thread. LocalServices lookups are deferred to onBootPhase so the
 * dependencies are guaranteed to be published. The HTTP server
 * holds a direct reference to this instance, so each endpoint
 * call is a plain Java method invocation.
 */

package com.qalos.remotectl;

import android.app.ActivityManager;
import android.app.IActivityManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.hardware.input.InputManager;
import android.os.RemoteException;
import android.os.SystemClock;
import android.os.UserHandle;
import android.util.Log;
import android.util.Size;
import android.view.Display;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceControl;

import com.android.server.LocalServices;
import com.android.server.SystemService;
import com.android.server.input.InputManagerService;

import java.io.ByteArrayOutputStream;
import java.util.List;

/**
 * System service that implements {@link IRemoteControl} and hosts
 * the embedded {@link HttpApiServer}.
 *
 * <p>Registered by {@code SystemServer} after
 * {@code InputManagerService} and {@code ActivityManagerService} have
 * started. The HTTP server binds to {@code 127.0.0.1:9000} by default
 * (see {@link #DEFAULT_BIND_LOCAL_ONLY}).
 */
public final class RemoteControlService extends SystemService implements IRemoteControl {
    private static final String TAG = "QaRemoteCtl";

    /** Default port. */
    static final int DEFAULT_PORT = 9000;

    /** Default bind address. See D-004 in the decisions log. */
    static final boolean DEFAULT_BIND_LOCAL_ONLY = true;

    private final Context mContext;

    private InputManagerService mInputManager;
    private IActivityManager mActivityManager;
    private DisplayManager mDisplayManager;

    private HttpApiServer mHttpServer;

    public RemoteControlService(Context context) {
        super(context);
        mContext = context;
    }

    @Override
    public void onStart() {
        // The HTTP server is the only v0 client; it holds a direct
        // reference to this instance. We do not publish the service
        // over Binder (no AIDL in v0).
        mHttpServer = new HttpApiServer(
                DEFAULT_PORT,
                this,
                DEFAULT_BIND_LOCAL_ONLY);
        mHttpServer.start();
        Log.i(TAG, "remote control service ready on port " + DEFAULT_PORT);
    }

    @Override
    public void onBootPhase(int phase) {
        Log.i(TAG, "onBootPhase: " + phase);
        if (phase == PHASE_LOCKED_BOOT_COMPLETED) {
            mInputManager = LocalServices.getService(InputManagerService.class);
            mActivityManager = LocalServices.getService(IActivityManager.class);
            mDisplayManager =
                    (DisplayManager) mContext.getSystemService(Context.DISPLAY_SERVICE);
        }
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "onDestroy: shutting down HTTP server");
        if (mHttpServer != null) {
            mHttpServer.shutdown();
        }
    }

    // ------------------------------------------------------------------
    // IRemoteControl — input
    // ------------------------------------------------------------------

    @Override
    public void tap(int x, int y, int displayId) {
        enforceCoordinatesOnDisplay(x, y, displayId);
        injectTap(x, y, displayId);
    }

    @Override
    public void typeText(String text) {
        if (text == null) {
            throw new IllegalArgumentException("text must not be null");
        }
        // Hard cap to keep one keystroke burst from wedging the worker.
        if (text.length() > 1024) {
            throw new IllegalArgumentException("text too long (>1024 chars)");
        }
        injectText(text);
    }

    @Override
    public void keyEvent(int keyCode, boolean down) {
        injectKey(keyCode, down);
    }

    // ------------------------------------------------------------------
    // IRemoteControl — app lifecycle
    // ------------------------------------------------------------------

    @Override
    public void launchApp(String packageName) {
        enforcePackageName(packageName);
        launchAppInternal(packageName);
    }

    @Override
    public void forceStop(String packageName) {
        enforcePackageName(packageName);
        forceStopInternal(packageName);
    }

    // ------------------------------------------------------------------
    // IRemoteControl — queries
    // ------------------------------------------------------------------

    @Override
    public String getForegroundPackage() {
        return getForegroundPackageInternal();
    }

    @Override
    public int getDisplayWidth(int displayId) {
        return getDisplaySizeInternal(displayId).getWidth();
    }

    @Override
    public int getDisplayHeight(int displayId) {
        return getDisplaySizeInternal(displayId).getHeight();
    }

    @Override
    public String screenshotBase64(int width, int height, int displayId, int quality) {
        return screenshotBase64Internal(width, height, displayId, quality);
    }

    // ------------------------------------------------------------------
    // Input injection
    // ------------------------------------------------------------------

    private void injectTap(int x, int y, int displayId) {
        final long now = SystemClock.uptimeMillis();
        final MotionEvent down = MotionEvent.obtain(
                now, now, MotionEvent.ACTION_DOWN, x, y,
                /* pressure */ 1.0f,
                /* size */ 1.0f,
                /* metaState */ 0,
                /* xPrecision */ 1.0f,
                /* yPrecision */ 1.0f,
                /* deviceId */ 0,
                /* edgeFlags */ 0);
        final MotionEvent up = MotionEvent.obtain(
                now, now, MotionEvent.ACTION_UP, x, y,
                /* pressure */ 0.0f,
                /* size */ 0.0f,
                /* metaState */ 0,
                /* xPrecision */ 1.0f,
                /* yPrecision */ 1.0f,
                /* deviceId */ 0,
                /* edgeFlags */ 0);
        if (displayId != 0) {
            down.setDisplayId(displayId);
            up.setDisplayId(displayId);
        }
        try {
            injectEvent(down);
            injectEvent(up);
        } finally {
            // Recycle even on the error path so a failed tap does not
            // leak a MotionEvent allocation.
            down.recycle();
            up.recycle();
        }
    }

    private void injectText(String text) {
        final KeyCharacterMap kcm = KeyCharacterMap.getInstance(
                KeyCharacterMap.VIRTUAL_KEYBOARD);
        final KeyEvent[] events = kcm.getEvents(text.toCharArray());
        if (events == null) {
            // Some characters (CJK, emoji) cannot be expressed as key
            // events. Surface a typed error rather than silently
            // dropping the call.
            throw new IllegalArgumentException(
                    "text contains characters that cannot be typed as key events");
        }
        for (KeyEvent event : events) {
            injectKeyEvent(event);
        }
    }

    private void injectKey(int keyCode, boolean down) {
        final long now = SystemClock.uptimeMillis();
        final int action = down ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP;
        final KeyEvent event = new KeyEvent(
                now, now, action, keyCode, /* repeat */ 0,
                /* metaState */ 0, /* deviceId */ 0,
                /* scancode */ 0,
                KeyEvent.FLAG_FROM_SOURCE | KeyEvent.FLAG_SOFT_KEYBOARD,
                InputDevice.SOURCE_KEYBOARD);
        injectKeyEvent(event);
    }

    private void injectKeyEvent(KeyEvent event) {
        if (mInputManager == null) {
            throw new IllegalStateException("InputManagerService not available");
        }
        mInputManager.injectInputEvent(event,
                InputManager.INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH);
    }

    private void injectEvent(MotionEvent event) {
        if (mInputManager == null) {
            throw new IllegalStateException("InputManagerService not available");
        }
        mInputManager.injectInputEvent(event,
                InputManager.INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH);
    }

    // ------------------------------------------------------------------
    // App lifecycle
    // ------------------------------------------------------------------

    private void launchAppInternal(String packageName) {
        // `ActivityManager.getLaunchIntentForPackage` was deprecated in
        // API 33. The non-deprecated path is the same call on
        // `PackageManager`. Same logic, same intent shape, just the
        // canonical home.
        final Intent launch = mContext.getPackageManager()
                .getLaunchIntentForPackage(packageName);
        if (launch == null) {
            throw new IllegalArgumentException("package not installed: " + packageName);
        }
        try {
            // `Context.startActivity` for the system_server caller still
            // routes through the ActivityManager service; we use the
            // `FLAG_ACTIVITY_NEW_TASK` flag because the caller is a
            // service (no task stack of its own).
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            mContext.startActivity(launch);
        } catch (SecurityException e) {
            throw new IllegalStateException("failed to start activity", e);
        }
    }

    private void forceStopInternal(String packageName) {
        if (mActivityManager == null) {
            throw new IllegalStateException("IActivityManager not available");
        }
        try {
            mActivityManager.forceStopPackage(packageName, UserHandle.getCallingUserId());
        } catch (RemoteException e) {
            throw new IllegalStateException("failed to force stop", e);
        }
    }

    // ------------------------------------------------------------------
    // Queries
    // ------------------------------------------------------------------

    private String getForegroundPackageInternal() {
        if (mActivityManager == null) {
            throw new IllegalStateException("IActivityManager not available");
        }
        try {
            // Use the AIDL binder directly. The app-side
            // `ActivityManager.getRunningTasks(int)` was deprecated in API
            // 21 and hard-removed in API 35 (Android 15) — the public
            // shim no longer exposes it. The system_server-side
            // `IActivityManager.getTasks(int maxNum)` is the supported
            // replacement and is callable from system_server without a
            // permission gate (the server side allows system_server
            // callers unconditionally).
            final List<ActivityManager.RunningTaskInfo> tasks =
                    mActivityManager.getTasks(1);
            if (tasks == null || tasks.isEmpty()) {
                return "";
            }
            final android.content.ComponentName top = tasks.get(0).topActivity;
            return top == null ? "" : top.getPackageName();
        } catch (RemoteException e) {
            throw new IllegalStateException("failed to get foreground task", e);
        }
    }

    private Size getDisplaySizeInternal(int displayId) {
        if (mDisplayManager == null) {
            throw new IllegalStateException("DisplayManager not available");
        }
        final Display display = mDisplayManager.getDisplay(displayId);
        if (display == null) {
            throw new IllegalArgumentException("display not found: " + displayId);
        }
        // `Display.getRealSize` was deprecated in API 30. The modern
        // equivalent is `Context#getDisplay().getRealSize(DisplayMetrics)`,
        // which avoids the deprecated `WindowManager.getDefaultDisplay()`
        // path. The size on `Display` is in pixels, same units as the
        // legacy API; tap coordinates are also in pixels.
        final android.graphics.Point size = new android.graphics.Point();
        mContext.getDisplay().getRealSize(size);
        return Size.of(size.x, size.y);
    }

    // ------------------------------------------------------------------
    // Screenshot
    // ------------------------------------------------------------------

    private String screenshotBase64Internal(int width, int height, int displayId, int quality) {
        if (quality < 1 || quality > 100) {
            throw new IllegalArgumentException("quality must be in [1, 100]");
        }
        final Size displaySize = getDisplaySizeInternal(displayId);
        final int w = width > 0 ? width : displaySize.getWidth();
        final int h = height > 0 ? height : displaySize.getHeight();
        // Use the modern `SurfaceControl.screenshot(Display, Rect, int)`
        // overload, not the legacy 4-arg `(Rect, int, int, int)` form
        // (deprecated in API 34; the legacy form still works on AOSP 15
        // but routes through an extra compatibility layer). The 3-arg
        // form takes the display directly, an optional source crop, and
        // a rotation in degrees.
        final Display display = mDisplayManager.getDisplay(displayId);
        if (display == null) {
            throw new IllegalArgumentException("display not found: " + displayId);
        }
        final Bitmap bitmap = SurfaceControl.screenshot(display, new Rect(), 0);
        if (bitmap == null) {
            throw new IllegalStateException("screenshot failed (SurfaceControl returned null)");
        }
        // Downscale if the caller asked for a smaller size. The
        // modern screenshot always returns the display's full
        // resolution; resizing after capture keeps the on-screen
        // content at full quality before the resize.
        final Bitmap scaled = (bitmap.getWidth() == w && bitmap.getHeight() == h)
                ? bitmap
                : Bitmap.createScaledBitmap(bitmap, w, h, /* filter */ true);
        if (scaled != bitmap) {
            bitmap.recycle();
        }
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        scaled.compress(Bitmap.CompressFormat.PNG, quality, out);
        scaled.recycle();
        return android.util.Base64.encodeToString(
                out.toByteArray(), android.util.Base64.NO_WRAP);
    }

    // ------------------------------------------------------------------
    // Validation
    // ------------------------------------------------------------------

    private void enforceCoordinatesOnDisplay(int x, int y, int displayId) {
        if (x < 0 || y < 0) {
            throw new IllegalArgumentException("coordinates must be non-negative");
        }
        final Size size = getDisplaySizeInternal(displayId);
        final int w = size.getWidth();
        final int h = size.getHeight();
        if (x >= w || y >= h) {
            throw new IllegalArgumentException(
                    "coordinates (" + x + "," + y + ") outside display "
                            + displayId + " (" + w + "x" + h + ")");
        }
    }

    private static void enforcePackageName(String packageName) {
        if (packageName == null) {
            throw new IllegalArgumentException("packageName must not be null");
        }
        if (packageName.isEmpty()
                || !Character.isJavaIdentifierStart(packageName.charAt(0))
                || packageName.contains("..")
                || packageName.startsWith(".")
                || packageName.endsWith(".")) {
            throw new IllegalArgumentException("invalid packageName: " + packageName);
        }
        for (int i = 1; i < packageName.length(); i++) {
            final char c = packageName.charAt(i);
            if (c != '.' && !Character.isJavaIdentifierPart(c)) {
                throw new IllegalArgumentException("invalid packageName: " + packageName);
            }
        }
    }
}
