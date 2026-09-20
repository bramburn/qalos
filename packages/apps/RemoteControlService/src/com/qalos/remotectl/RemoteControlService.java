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

import com.android.server.LocalServices;
import com.android.server.SystemService;
import com.android.server.input.InputManagerService;

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
    // v1 opens the API to LAN/WAN; token auth is the access control.
    static final boolean DEFAULT_BIND_LOCAL_ONLY = false;

    private final Context mContext;

    // The three service references below are written in
    // `onBootPhase(PHASE_BOOT_COMPLETED)` on the system_server main
    // thread and read on the per-connection HTTP handler threads.
    // Marked `volatile` so the JMM guarantees the handler threads see
    // the published references without a synchronisation edge. Caught
    // by the v0.1 review: without `volatile`, a handler that races
    // the boot-phase write could see stale `null` and throw
    // IllegalStateException. (Review item 2.3.)
    private volatile InputManagerService mInputManager;
    private volatile IActivityManager mActivityManager;
    private volatile DisplayManager mDisplayManager;

    private HttpApiServer mHttpServer;

    private static final String TOKEN_PATH = "/data/local/tmp/qalos_token";

    public RemoteControlService(Context context) {
        super(context);
        mContext = context;
    }

    @Override
    public void onStart() {
        ensureTokenExists();
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
        if (phase == PHASE_BOOT_COMPLETED) {
            mInputManager = LocalServices.getService(InputManagerService.class);
            mActivityManager = LocalServices.getService(IActivityManager.class);
            mDisplayManager =
                    (DisplayManager) mContext.getSystemService(Context.DISPLAY_SERVICE);
        }
    }

    // Note: AOSP 15 removed SystemService.onDestroy(); the lifecycle ends
    // when system_server exits. The HTTP server is a daemon thread
    // (set via HttpApiServer.setDaemon(true)) so it dies with
    // system_server automatically — no shutdown hook needed.

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
    // IRemoteControl — gestures
    // ------------------------------------------------------------------

    @Override
    public void longPress(int x, int y, int durationMs, int displayId) {
        if (durationMs <= 0) {
            throw new IllegalArgumentException("durationMs must be positive");
        }
        enforceCoordinatesOnDisplay(x, y, displayId);
        injectLongPress(x, y, durationMs, displayId);
    }

    @Override
    public void swipe(int x1, int y1, int x2, int y2, int durationMs, int displayId) {
        if (durationMs <= 0) {
            throw new IllegalArgumentException("durationMs must be positive");
        }
        enforceCoordinatesOnDisplay(x1, y1, displayId);
        enforceCoordinatesOnDisplay(x2, y2, displayId);
        injectSwipe(x1, y1, x2, y2, durationMs, displayId);
    }

    @Override
    public void pinch(float x, float y, float scale, int durationMs, int displayId) {
        if (scale <= 0) {
            throw new IllegalArgumentException("scale must be positive");
        }
        // No-op for identity scale — same as a tap, nothing to zoom.
        if (Math.abs(scale - 1.0f) < 0.001f) {
            return;
        }
        injectPinch(x, y, scale, durationMs, displayId);
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

    private void injectLongPress(int x, int y, int durationMs, int displayId) {
        final long now = SystemClock.uptimeMillis();
        final MotionEvent down = MotionEvent.obtain(
                now, now, MotionEvent.ACTION_DOWN, x, y,
                1.0f, 1.0f, 0, 1.0f, 1.0f, 0, 0);
        final MotionEvent up = MotionEvent.obtain(
                now, now + durationMs, MotionEvent.ACTION_UP, x, y,
                0.0f, 0.0f, 0, 1.0f, 1.0f, 0, 0);
        if (displayId != 0) {
            down.setDisplayId(displayId);
            up.setDisplayId(displayId);
        }
        try {
            injectEvent(down);
            Thread.sleep(durationMs);
            injectEvent(up);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            Log.w(TAG, "longPress interrupted");
        } finally {
            down.recycle();
            up.recycle();
        }
    }

    private void injectSwipe(int x1, int y1, int x2, int y2,
            int durationMs, int displayId) {
        final long startTime = SystemClock.uptimeMillis();
        final int steps = Math.max(1, durationMs / 50);
        final long stepDuration = durationMs / steps;

        // DOWN at start position
        final MotionEvent down = MotionEvent.obtain(
                startTime, startTime, MotionEvent.ACTION_DOWN, x1, y1,
                1.0f, 1.0f, 0, 1.0f, 1.0f, 0, 0);
        if (displayId != 0) down.setDisplayId(displayId);

        MotionEvent prev = down;
        try {
            injectEvent(down);
            for (int i = 1; i <= steps; i++) {
                final long eventTime = startTime + (i * stepDuration);
                final float t = (float) i / steps;
                final int cx = (int) (x1 + (x2 - x1) * t);
                final int cy = (int) (y1 + (y2 - y1) * t);
                final int action = (i == steps)
                        ? MotionEvent.ACTION_UP
                        : MotionEvent.ACTION_MOVE;
                final MotionEvent me = MotionEvent.obtain(
                        startTime, eventTime, action, cx, cy,
                        1.0f, 1.0f, 0, 1.0f, 1.0f, 0, 0);
                if (displayId != 0) me.setDisplayId(displayId);
                try {
                    injectEvent(me);
                } finally {
                    me.recycle();
                }
            }
        } finally {
            down.recycle();
        }
    }

    private void injectPinch(float centreX, float centreY, float scale,
            int durationMs, int displayId) {
        final long startTime = SystemClock.uptimeMillis();
        final long stepDuration = durationMs / 3;

        final float offset = 50.0f;
        // Pointer positions at scale=1.0: centred on (centreX, centreY)
        final float p1x0 = centreX - offset;
        final float p1y0 = centreY - offset;
        final float p2x0 = centreX + offset;
        final float p2y0 = centreY + offset;

        // Pointer indices: 0 and 1
        final int pointerIndex0 = 0;
        final int pointerIndex1 = 1;

        // POINTER_DOWN for first pointer (both pointers touch down)
        final MotionEvent.PointerCoords[] coords0 = new MotionEvent.PointerCoords[2];
        coords0[0] = new MotionEvent.PointerCoords();
        coords0[0].x = p1x0;
        coords0[0].y = p1y0;
        coords0[0].pressure = 1.0f;
        coords0[0].size = 1.0f;
        coords0[1] = new MotionEvent.PointerCoords();
        coords0[1].x = p2x0;
        coords0[1].y = p2y0;
        coords0[1].pressure = 1.0f;
        coords0[1].size = 1.0f;

        final MotionEvent.PointerProperties[] props = new MotionEvent.PointerProperties[2];
        props[0] = new MotionEvent.PointerProperties();
        props[0].id = 0;
        props[0].toolType = MotionEvent.TOOL_TYPE_FINGER;
        props[1] = new MotionEvent.PointerProperties();
        props[1].id = 1;
        props[1].toolType = MotionEvent.TOOL_TYPE_FINGER;

        // Build the event history for MOVE steps
        final float[] scales = new float[] { 1.0f + (scale - 1.0f) / 3,
                1.0f + 2 * (scale - 1.0f) / 3, scale };

        MotionEvent downEvent = null;
        MotionEvent moveEvent1 = null;
        MotionEvent moveEvent2 = null;
        MotionEvent moveEvent3 = null;
        MotionEvent upEvent = null;

        try {
            // ACTION_POINTER_DOWN (both pointers)
            downEvent = MotionEvent.obtain(startTime, startTime,
                    MotionEvent.ACTION_POINTER_DOWN
                            | (pointerIndex0 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    2, props, coords0,
                    0, 0, 1.0f, 1.0f, 0, 0, 0, 0);
            if (displayId != 0) downEvent.setDisplayId(displayId);
            injectEvent(downEvent);

            long prevTime = startTime;
            for (int i = 0; i < 3; i++) {
                final long eventTime = startTime + ((i + 1) * stepDuration);
                final float s = scales[i];
                final MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[2];
                coords[0] = new MotionEvent.PointerCoords();
                coords[0].x = centreX - (offset * s);
                coords[0].y = centreY - (offset * s);
                coords[0].pressure = 1.0f;
                coords[0].size = 1.0f;
                coords[1] = new MotionEvent.PointerCoords();
                coords[1].x = centreX + (offset * s);
                coords[1].y = centreY + (offset * s);
                coords[1].pressure = 1.0f;
                coords[1].size = 1.0f;

                MotionEvent me = MotionEvent.obtain(prevTime, eventTime,
                        MotionEvent.ACTION_MOVE, 2, props, coords,
                        0, 0, 1.0f, 1.0f, 0, 0, 0, 0);
                if (displayId != 0) me.setDisplayId(displayId);
                try {
                    injectEvent(me);
                } finally {
                    me.recycle();
                }
                prevTime = eventTime;
            }

            // POINTER_UP (both pointers lift)
            final MotionEvent.PointerCoords[] coordsUp = new MotionEvent.PointerCoords[2];
            coordsUp[0] = new MotionEvent.PointerCoords();
            coordsUp[0].x = centreX - (offset * scale);
            coordsUp[0].y = centreY - (offset * scale);
            coordsUp[0].pressure = 0.0f;
            coordsUp[0].size = 0.0f;
            coordsUp[1] = new MotionEvent.PointerCoords();
            coordsUp[1].x = centreX + (offset * scale);
            coordsUp[1].y = centreY + (offset * scale);
            coordsUp[1].pressure = 0.0f;
            coordsUp[1].size = 0.0f;

            upEvent = MotionEvent.obtain(prevTime, prevTime,
                    MotionEvent.ACTION_POINTER_UP
                            | (pointerIndex1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    2, props, coordsUp,
                    0, 0, 0.0f, 0.0f, 0, 0, 0, 0);
            if (displayId != 0) upEvent.setDisplayId(displayId);
            injectEvent(upEvent);

        } finally {
            if (downEvent != null) downEvent.recycle();
            if (upEvent != null) upEvent.recycle();
        }
    }

    private void injectText(String text) {
        // KeyCharacterMap.getInstance(int) was removed in AOSP 15; the
        // replacement is KeyCharacterMap.load(int). Both return a
        // KeyCharacterMap for the virtual keyboard device.
        final KeyCharacterMap kcm = KeyCharacterMap.load(
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
        // KeyEvent.FLAG_FROM_SOURCE was removed in AOSP 15. The
        // replacement for system-injected key events is
        // FLAG_SOFT_KEYBOARD (kept) plus the source-bit on the
        // constructor (kept as InputDevice.SOURCE_KEYBOARD).
        final KeyEvent event = new KeyEvent(
                now, now, action, keyCode, /* repeat */ 0,
                /* metaState */ 0, /* deviceId */ 0,
                /* scancode */ 0,
                KeyEvent.FLAG_SOFT_KEYBOARD,
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
        // Use the fetched `display` (not `mContext.getDisplay()`, which
        // is always the default display) — otherwise `displayId` is
        // validated and then ignored. Caught by the v0.1 review: the
        // previous code called `mContext.getDisplay().getRealSize(size)`,
        // which made `enforceCoordinatesOnDisplay` validate coordinates
        // against the wrong display on multi-display emulators.
        //
        // `Display.getRealSize(Point)` was deprecated in API 30 (R).
        // In AOSP 15 `Display.Mode.getResolution()` was removed entirely,
        // and `Display.Mode` no longer exposes public `getWidth`/`getHeight`
        // either (those exist on `Display` itself, but not on `Mode`).
        // The public API on `Display.Mode` in API 35 is `getModeId`,
        // `getPhysicalWidth`, `getPhysicalHeight`, `getRefreshRate`. Use
        // the physical dimensions to match the resolution callers expect.
        final android.util.Size resolution = new android.util.Size(
                display.getMode().getPhysicalWidth(),
                display.getMode().getPhysicalHeight());
        return new Size(resolution.getWidth(), resolution.getHeight());
    }

    // ------------------------------------------------------------------
    // Screenshot
    // ------------------------------------------------------------------

    private String screenshotBase64Internal(int width, int height, int displayId, int quality) {
        if (quality < 1 || quality > 100) {
            throw new IllegalArgumentException("quality must be in [1, 100]");
        }
        // AOSP 15 path (synchronous — see D-018):
        //   ScreenCapture.captureDisplay(int)  →  ScreenshotHardwareBuffer
        //     →  Bitmap.wrapHardwareBuffer(hw, colorSpace)
        //     →  optional aspect-ratio-preserving scale via Bitmap.createScaledBitmap
        //     →  PNG (lossless; the `quality` param is a JPEG-style knob we accept
        //            but ignore because PNG has no quality axis)
        //     →  Base64.NO_WRAP
        //
        // The capture call is synchronous on AOSP 15 (no CountDownLatch / Executor
        // needed). It must be invoked from a thread that is allowed to take a
        // display buffer — a per-connection HTTP handler thread on
        // system_server is fine (WindowManager allows system_server reads).
        final android.window.ScreenCapture.ScreenshotHardwareBuffer hwBuf =
                android.window.ScreenCapture.captureDisplay(displayId);
        if (hwBuf == null) {
            throw new IllegalStateException("ScreenCapture.captureDisplay returned null");
        }
        final android.hardware.HardwareBuffer buffer = hwBuf.getHardwareBuffer();
        if (buffer == null) {
            hwBuf.close();
            throw new IllegalStateException("ScreenshotHardwareBuffer has no HardwareBuffer");
        }
        final android.graphics.ColorSpace colorSpace = hwBuf.getColorSpace();
        android.graphics.Bitmap bitmap = null;
        android.graphics.Bitmap scaledBitmap = null;
        final java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream();
        try {
            bitmap = android.graphics.Bitmap.wrapHardwareBuffer(
                    buffer,
                    colorSpace != null ? colorSpace : android.graphics.ColorSpace.get(
                            android.graphics.ColorSpace.Named.SRGB));
            if (bitmap == null) {
                throw new IllegalStateException("Bitmap.wrapHardwareBuffer returned null");
            }
            // Aspect-ratio-preserving scale if the caller asked for a
            // specific size. width == height == 0 means "native display
            // size", in which case we skip the scale step entirely.
            if (width > 0 && height > 0
                    && (bitmap.getWidth() != width || bitmap.getHeight() != height)) {
                final float srcAspect = (float) bitmap.getWidth() / bitmap.getHeight();
                final float dstAspect = (float) width / height;
                final int targetW;
                final int targetH;
                if (srcAspect > dstAspect) {
                    // Source is wider than target → fit width, height letter-boxes.
                    targetW = width;
                    targetH = Math.round(width / srcAspect);
                } else {
                    // Source is taller than target (or equal) → fit height.
                    targetH = height;
                    targetW = Math.round(height * srcAspect);
                }
                scaledBitmap = android.graphics.Bitmap.createScaledBitmap(
                        bitmap, targetW, targetH, /* filter */ true);
                if (scaledBitmap != bitmap) {
                    // createScaledBitmap returns the source Bitmap unchanged when the
                    // dimensions already match — we already checked that, so this
                    // branch is the expected one. Belt-and-braces recycle below.
                    bitmap.recycle();
                    bitmap = scaledBitmap;
                } else {
                    scaledBitmap = null;
                }
            }
            // PNG is lossless; the `quality` argument is part of the API contract
            // but ignored for PNG output. Bitmap.compress treats PNG quality as
            // a hint (it can affect compression effort at the cost of CPU).
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, baos);
            return android.util.Base64.encodeToString(baos.toByteArray(),
                    android.util.Base64.NO_WRAP);
        } finally {
            try {
                baos.close();
            } catch (java.io.IOException ignored) {
                // ByteArrayOutputStream.close is a no-op; can't fail.
            }
            if (scaledBitmap != null && scaledBitmap != bitmap) {
                scaledBitmap.recycle();
            }
            if (bitmap != null) {
                bitmap.recycle();
            }
            buffer.close();
            hwBuf.close();
        }
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

    private void ensureTokenExists() {
        java.io.File tokenFile = new java.io.File(TOKEN_PATH);
        if (tokenFile.exists()) return;
        try {
            java.security.SecureRandom sr = new java.security.SecureRandom();
            byte[] bytes = new byte[32];
            sr.nextBytes(bytes);
            String hex = javax.xml.bind.DatatypeConverter.printHexBinary(bytes);
            java.nio.file.Files.writeString(
                    tokenFile.toPath(), hex,
                    java.nio.file.StandardOpenOption.CREATE,
                    java.nio.file.StandardOpenOption.EXCLUSIVE);
            tokenFile.setReadable(true, false);  // 0644 world-readable
            Log.i(TAG, "generated new bearer token at " + TOKEN_PATH);
        } catch (java.io.IOException e) {
            Log.e(TAG, "failed to generate bearer token", e);
        }
    }
}
