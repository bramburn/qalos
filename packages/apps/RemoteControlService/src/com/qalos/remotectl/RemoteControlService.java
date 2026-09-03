// SPDX-License-Identifier: Apache-2.0
/*
 * qalos — Remote Control Service.
 *
 * System service that runs inside system_server and exposes a small
 * native API (input injection, screenshot, app lifecycle) to the
 * embedded HttpApiServer. The HTTP/JSON surface is the only thing
 * external callers should use; IRemoteControl is internal.
 *
 * Threading: the service is instantiated on the system_server main
 * thread. LocalServices lookups are deferred to onBootPhase so the
 * dependencies are guaranteed to be published. The Binder stub is
 * thread-safe; each call is short and runs on a binder thread.
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
import android.os.IRemoteControl;
import android.os.SystemClock;
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
 * System service that hosts {@link IRemoteControl} and the embedded
 * {@link HttpApiServer}.
 *
 * <p>The service is registered by {@code SystemServer} after
 * {@code InputManagerService} and {@code ActivityManagerService} have
 * started. The HTTP server binds to {@code 127.0.0.1:9000} by default
 * (see {@link #DEFAULT_BIND_LOCAL_ONLY}).
 */
public final class RemoteControlService extends SystemService {
    private static final String TAG = "QaRemoteCtl";

    /** Default port. */
    static final int DEFAULT_PORT = 9000;

    /** Default bind address. See D-004 in the decisions log. */
    static final boolean DEFAULT_BIND_LOCAL_ONLY = true;

    private final Context mContext;

    private InputManagerService mInputManager;
    private IActivityManager mActivityManager;
    private ActivityManager mActivityManagerClient;
    private DisplayManager mDisplayManager;

    private HttpApiServer mHttpServer;

    private final IRemoteControl.Stub mBinder = new IRemoteControl.Stub() {
        @Override
        public void tap(int x, int y, int displayId) {
            // Binder-level guard: only callers holding
            // android.permission.REMOTE_CONTROL may invoke us. The
            // system_server process self-binds; this check documents
            // the trust model and defends against future regressions
            // where some other system process tries to call us.
            enforceCallingPermission();
            enforceCoordinatesOnDisplay(x, y, displayId);
            injectTap(x, y, displayId);
        }

        @Override
        public void typeText(String text) {
            enforceCallingPermission();
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
            enforceCallingPermission();
            injectKey(keyCode, down);
        }

        @Override
        public void launchApp(String packageName) {
            enforceCallingPermission();
            enforcePackageName(packageName);
            launchAppInternal(packageName);
        }

        @Override
        public void forceStop(String packageName) {
            enforceCallingPermission();
            enforcePackageName(packageName);
            forceStopInternal(packageName);
        }

        @Override
        public String getForegroundPackage() {
            enforceCallingPermission();
            return getForegroundPackageInternal();
        }

        @Override
        public int getDisplayWidth(int displayId) {
            enforceCallingPermission();
            return getDisplaySizeInternal(displayId).getWidth();
        }

        @Override
        public int getDisplayHeight(int displayId) {
            enforceCallingPermission();
            return getDisplaySizeInternal(displayId).getHeight();
        }

        @Override
        public String screenshotBase64(int width, int height, int displayId, int quality) {
            enforceCallingPermission();
            return screenshotBase64Internal(width, height, displayId, quality);
        }

        private void enforceCallingPermission() {
            enforceCallingPermission(android.Manifest.permission.REMOTE_CONTROL,
                    "qalos RemoteControl");
        }
    };

    public RemoteControlService(Context context) {
        super(context);
        mContext = context;
    }

    @Override
    public void onStart() {
        // Do NOT look up LocalServices here — they are not registered
        // yet at the time onStart runs. The actual lookups happen in
        // onBootPhase below.
        publishBinderService("qalos_remote_control", mBinder);
        mHttpServer = new HttpApiServer(
                DEFAULT_PORT,
                mBinder,
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
            mActivityManagerClient =
                    (ActivityManager) mContext.getSystemService(Context.ACTIVITY_SERVICE);
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
        if (mActivityManagerClient == null) {
            throw new IllegalStateException("ActivityManager not available");
        }
        // startActivityAsUser on the IActivityManager Binder requires
        // a non-null Intent. Construct ACTION_MAIN + CATEGORY_LAUNCHER
        // scoped to the requested package; the system will pick the
        // default activity.
        final Intent launch = mActivityManagerClient.getLaunchIntentForPackage(packageName);
        if (launch == null) {
            throw new IllegalArgumentException("package not installed: " + packageName);
        }
        try {
            mActivityManagerClient.startActivity(launch);
        } catch (SecurityException e) {
            throw new IllegalStateException("failed to start activity", e);
        }
    }

    private void forceStopInternal(String packageName) {
        if (mActivityManagerClient == null) {
            throw new IllegalStateException("ActivityManager not available");
        }
        mActivityManagerClient.killBackgroundProcesses(packageName);
    }

    // ------------------------------------------------------------------
    // Queries
    // ------------------------------------------------------------------

    private String getForegroundPackageInternal() {
        if (mActivityManagerClient == null) {
            throw new IllegalStateException("ActivityManager not available");
        }
        // getRunningTasks was deprecated in AOSP 14 and may be removed
        // in later releases. The supported path is via the
        // ActivityTaskManager system service. For v0 we accept the
        // deprecation; the result is the package name of the top
        // focused task, or an empty string if the home screen is
        // focused.
        @SuppressWarnings("deprecation")
        final List<ActivityManager.RunningTaskInfo> tasks =
                mActivityManagerClient.getRunningTasks(1);
        if (tasks == null || tasks.isEmpty()) {
            return "";
        }
        final android.content.ComponentName top = tasks.get(0).topActivity;
        return top == null ? "" : top.getPackageName();
    }

    private Size getDisplaySizeInternal(int displayId) {
        if (mDisplayManager == null) {
            throw new IllegalStateException("DisplayManager not available");
        }
        final Display display = mDisplayManager.getDisplay(displayId);
        if (display == null) {
            throw new IllegalArgumentException("display not found: " + displayId);
        }
        final android.graphics.Point size = new android.graphics.Point();
        display.getRealSize(size);
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
        final Bitmap bitmap = SurfaceControl.screenshot(
                new Rect(), w, h, displayId);
        if (bitmap == null) {
            throw new IllegalStateException("screenshot failed (SurfaceControl returned null)");
        }
        // The Bitmap is not recycled explicitly; Bitmap.recycle() is
        // deprecated in API 28+ and can crash if a soft reference to
        // the bitmap still exists. The GC will reclaim it.
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, quality, out);
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
        // Java package grammar: lowercase letters, digits, underscores,
        // dots; must not be empty; must not start with a digit; must
        // not contain two consecutive dots; must not start or end
        // with a dot.
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
