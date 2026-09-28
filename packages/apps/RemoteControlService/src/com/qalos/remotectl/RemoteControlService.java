// SPDX-License-Identifier: Apache-2.0
/*
 * qalos â€” Remote Control Service.
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
import android.graphics.Bitmap;
import android.graphics.ColorSpace;
import android.hardware.HardwareBuffer;
import android.util.Base64;
import android.util.Log;
import android.util.Size;
import android.view.Display;
import android.window.ScreenCapture;
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
        // Read the bearer token once at startup and pass it to the
        // HTTP server. This eliminates the per-request disk read
        // (review item #6) and means the token path lives in one
        // place (review item #5). If the token file is missing or
        // unreadable we still start the HTTP server â€” but token
        // validation will fail for every non-loopback request, which
        // is the safe failure mode (operators see auth errors, not
        // silent data leaks).
        final String bearerToken = readBearerToken();
        if (bearerToken == null) {
            Log.w(TAG, "bearer token not readable; non-loopback auth will reject all requests");
        }
        // The HTTP server is the only v0 client; it holds a direct
        // reference to this instance. We do not publish the service
        // over Binder (no AIDL in v0).
        mHttpServer = new HttpApiServer(
                DEFAULT_PORT,
                this,
                DEFAULT_BIND_LOCAL_ONLY,
                bearerToken);
        mHttpServer.start();
        Log.i(TAG, "remote control service ready on port " + DEFAULT_PORT);
    }

    private static String readBearerToken() {
        final java.io.File tokenFile = new java.io.File(TOKEN_PATH);
        if (!tokenFile.exists()) {
            return null;
        }
        try {
            return new String(java.nio.file.Files.readAllBytes(tokenFile.toPath()),
                    java.nio.charset.StandardCharsets.UTF_8).trim();
        } catch (java.io.IOException e) {
            Log.e(TAG, "failed to read bearer token from " + TOKEN_PATH, e);
            return null;
        }
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
    // system_server automatically â€” no shutdown hook needed.

    // ------------------------------------------------------------------
    // IRemoteControl â€” input
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
    // IRemoteControl â€” gestures
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
        // No-op for identity scale â€” same as a tap, nothing to zoom.
        if (Math.abs(scale - 1.0f) < 0.001f) {
            return;
        }
        injectPinch(x, y, scale, durationMs, displayId);
    }

    // ------------------------------------------------------------------
    // IRemoteControl â€” app lifecycle
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
    // IRemoteControl â€” queries
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
        // The ACTION_UP must be sent even if the sleep is interrupted,
        // otherwise the input system stays in DOWN state and corrupts
        // subsequent touches. We catch InterruptedException and
        // continue to the UP, leaving the interrupt flag set so the
        // per-connection HTTP handler thread can see it later.
        boolean upSent = false;
        try {
            injectEvent(down);
            try {
                Thread.sleep(durationMs);
            } catch (InterruptedException e) {
                Log.w(TAG, "longPress interrupted mid-press; UP will still be sent");
            }
            injectEvent(up);
            upSent = true;
        } finally {
            if (!upSent) {
                // Best-effort UP. If this also fails we are in a
                // genuinely degraded state (e.g. InputManagerService
                // unavailable); log it and let the operator reset.
                Log.e(TAG, "longPress failed before UP could be sent; "
                        + "the device may have a stuck touch");
                try {
                    injectEvent(up);
                } catch (RuntimeException e) {
                    Log.e(TAG, "best-effort UP also failed", e);
                }
            }
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

        // Pointer indices into the coords[] / props[] arrays. The
        // ACTION_POINTER_INDEX_SHIFT bits on POINTER_DOWN / POINTER_UP
        // identify which array slot holds the *new* (or *lifting*)
        // pointer â€” not the pointer's id.
        final int pointerIndex0 = 0;
        final int pointerIndex1 = 1;

        // PointerProperties are shared across all events for this gesture.
        // id values are stable identifiers; toolType is FINGER for both.
        final MotionEvent.PointerProperties[] props = new MotionEvent.PointerProperties[2];
        props[pointerIndex0] = new MotionEvent.PointerProperties();
        props[pointerIndex0].id = 0;
        props[pointerIndex0].toolType = MotionEvent.TOOL_TYPE_FINGER;
        props[pointerIndex1] = new MotionEvent.PointerProperties();
        props[pointerIndex1].id = 1;
        props[pointerIndex1].toolType = MotionEvent.TOOL_TYPE_FINGER;

        // Build the event history for MOVE steps
        final float[] scales = new float[] { 1.0f + (scale - 1.0f) / 3,
                1.0f + 2 * (scale - 1.0f) / 3, scale };

        // Standard Android two-finger gesture sequence (this is what
        // pre-fix-bug fix #2 changed): the previous implementation
        // started with ACTION_POINTER_DOWN (no preceding ACTION_DOWN)
        // and ended with ACTION_POINTER_UP (no final ACTION_UP). Most
        // touch handlers reject the truncated sequence, so the pinch
        // gesture never actually worked end-to-end.
        //
        //   1. ACTION_DOWN         â€” pointer 0 (the first finger)
        //   2. ACTION_POINTER_DOWN â€” pointer 1 (the second finger joins)
        //   3. ACTION_MOVE Ã— N     â€” both pointers slide outward/inward
        //   4. ACTION_POINTER_UP   â€” pointer 1 lifts first
        //   5. ACTION_UP           â€” pointer 0 lifts last
        MotionEvent downEvent0 = null;
        MotionEvent pointerDownEvent = null;
        MotionEvent pointerUpEvent = null;
        MotionEvent upEvent1 = null;

        try {
            // 1. ACTION_DOWN â€” pointer 0 only (single-pointer event)
            downEvent0 = MotionEvent.obtain(
                    startTime, startTime, MotionEvent.ACTION_DOWN,
                    p1x0, p1y0,
                    1.0f, 1.0f, 0, 1.0f, 1.0f, 0, 0);
            if (displayId != 0) downEvent0.setDisplayId(displayId);
            injectEvent(downEvent0);

            // 2. ACTION_POINTER_DOWN â€” pointer 1 joins. The full
            // coords[] describes both pointers in their starting
            // positions; pointerIndex1 (1) is the new one.
            final MotionEvent.PointerCoords[] coords0 = newCoords(
                    centreX - offset, centreY - offset,
                    centreX + offset, centreY + offset,
                    1.0f);
            pointerDownEvent = MotionEvent.obtain(startTime, startTime,
                    MotionEvent.ACTION_POINTER_DOWN
                            | (pointerIndex1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    2, props, coords0,
                    0, 0, 1.0f, 1.0f, 0, 0, 0, 0);
            if (displayId != 0) pointerDownEvent.setDisplayId(displayId);
            injectEvent(pointerDownEvent);

            // 3. MOVE Ã— 3 â€” both pointers slide proportionally
            long prevTime = startTime;
            for (int i = 0; i < 3; i++) {
                final long eventTime = startTime + ((i + 1) * stepDuration);
                final float s = scales[i];
                final MotionEvent.PointerCoords[] coords = newCoords(
                        centreX - (offset * s), centreY - (offset * s),
                        centreX + (offset * s), centreY + (offset * s),
                        1.0f);
                final MotionEvent me = MotionEvent.obtain(prevTime, eventTime,
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

            // 4. ACTION_POINTER_UP â€” pointer 1 lifts. coords describe
            // pointer 0 at its post-pinch position and pointer 1 at
            // release coords with size=0; pointerIndex1 (1) is the
            // one going up.
            final MotionEvent.PointerCoords[] coordsUp = new MotionEvent.PointerCoords[2];
            coordsUp[pointerIndex0] = new MotionEvent.PointerCoords();
            coordsUp[pointerIndex0].x = centreX - (offset * scale);
            coordsUp[pointerIndex0].y = centreY - (offset * scale);
            coordsUp[pointerIndex0].pressure = 1.0f;
            coordsUp[pointerIndex0].size = 1.0f;
            coordsUp[pointerIndex1] = new MotionEvent.PointerCoords();
            coordsUp[pointerIndex1].x = centreX + (offset * scale);
            coordsUp[pointerIndex1].y = centreY + (offset * scale);
            coordsUp[pointerIndex1].pressure = 0.0f;
            coordsUp[pointerIndex1].size = 0.0f;

            pointerUpEvent = MotionEvent.obtain(prevTime, prevTime,
                    MotionEvent.ACTION_POINTER_UP
                            | (pointerIndex1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    2, props, coordsUp,
                    0, 0, 1.0f, 1.0f, 0, 0, 0, 0);
            if (displayId != 0) pointerUpEvent.setDisplayId(displayId);
            injectEvent(pointerUpEvent);

            // 5. ACTION_UP â€” pointer 0 lifts last (single-pointer event)
            upEvent1 = MotionEvent.obtain(prevTime, prevTime,
                    MotionEvent.ACTION_UP,
                    centreX - (offset * scale), centreY - (offset * scale),
                    0.0f, 0.0f, 0, 1.0f, 1.0f, 0, 0);
            if (displayId != 0) upEvent1.setDisplayId(displayId);
            injectEvent(upEvent1);

        } finally {
            if (downEvent0 != null) downEvent0.recycle();
            if (pointerDownEvent != null) pointerDownEvent.recycle();
            if (pointerUpEvent != null) pointerUpEvent.recycle();
            if (upEvent1 != null) upEvent1.recycle();
        }
    }

    /**
     * Allocate a 2-slot {@link MotionEvent.PointerCoords} array filled
     * with the two (x, y) pairs and a uniform pressure/size. Pulled
     * out of {@link #injectPinch} because the same allocation pattern
     * is repeated for ACTION_POINTER_DOWN, each MOVE step, and (with
     * different size for the lifted finger) ACTION_POINTER_UP.
     */
    private static MotionEvent.PointerCoords[] newCoords(
            float x0, float y0, float x1, float y1, float pressure) {
        final MotionEvent.PointerCoords[] out = new MotionEvent.PointerCoords[2];
        out[0] = new MotionEvent.PointerCoords();
        out[0].x = x0;
        out[0].y = y0;
        out[0].pressure = pressure;
        out[0].size = 1.0f;
        out[1] = new MotionEvent.PointerCoords();
        out[1].x = x1;
        out[1].y = y1;
        out[1].pressure = pressure;
        out[1].size = 1.0f;
        return out;
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
            // 21 and hard-removed in API 35 (Android 15) â€” the public
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
        // is always the default display) â€” otherwise `displayId` is
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
        // AOSP 15 path (synchronous â€” see D-018):
        //   ScreenCapture.captureDisplay(int)  â†’  ScreenshotHardwareBuffer
        //     â†’  Bitmap.wrapHardwareBuffer(hw, colorSpace)
        //     â†’  optional aspect-ratio-preserving scale via Bitmap.createScaledBitmap
        //     â†’  PNG (lossless; the `quality` param is a JPEG-style knob we accept
        //            but ignore because PNG has no quality axis)
        //     â†’  Base64.NO_WRAP
        //
        // The capture call is synchronous on AOSP 15 (no CountDownLatch / Executor
        // needed). It must be invoked from a thread that is allowed to take a
        // display buffer â€” a per-connection HTTP handler thread on
        // system_server is fine (WindowManager allows system_server reads).
        // AOSP 15 removed the captureDisplay(int) overload. The supported route
        // is DisplayManagerInternal.userScreenshot(int), which returns the same
        // ScreenCapture.ScreenshotHardwareBuffer and takes a plain display id:
        //   frameworks/base/core/java/android/hardware/display/
        //     DisplayManagerInternal.java:131
        //   userScreenshot(int displayId) -> ScreenshotHardwareBuffer
        // It is @hide "only for use within the system server" and is published
        // via publishLocalService(), so LocalServices.get() reaches it from here.
        // Avoids the DisplayCaptureArgs builder, which would need an IBinder
        // display token we have no public way to obtain.
        final android.hardware.display.DisplayManagerInternal dmi =
                LocalServices.get(android.hardware.display.DisplayManagerInternal.class);
        final android.window.ScreenCapture.ScreenshotHardwareBuffer hwBuf =
                dmi.userScreenshot(displayId);
        if (hwBuf == null) {
            throw new IllegalStateException("userScreenshot returned null");
        }
        final android.hardware.HardwareBuffer buffer = hwBuf.getHardwareBuffer();
        if (buffer == null) {
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
                    // Source is wider than target â†’ fit width, height letter-boxes.
                    targetW = width;
                    targetH = Math.round(width / srcAspect);
                } else {
                    // Source is taller than target (or equal) â†’ fit height.
                    targetH = height;
                    targetW = Math.round(height * srcAspect);
                }
                scaledBitmap = android.graphics.Bitmap.createScaledBitmap(
                        bitmap, targetW, targetH, /* filter */ true);
                if (scaledBitmap != bitmap) {
                    // createScaledBitmap returns the source Bitmap unchanged when the
                    // dimensions already match â€” we already checked that, so this
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
            // javax.xml.bind (JAXB) is not on the Android platform and
            // java.nio.file.Files.writeString is a Java 11 API absent from
            // android.jar. android.util.Base64 is already imported.
            final String hex = Base64.encodeToString(
                    bytes, Base64.NO_WRAP | Base64.NO_PADDING);
            try (java.io.FileOutputStream fos =
                    new java.io.FileOutputStream(tokenFile)) {
                fos.write(hex.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            tokenFile.setReadable(true, false);  // 0644 world-readable
            Log.i(TAG, "generated new bearer token at " + TOKEN_PATH);
        } catch (java.io.IOException e) {
            Log.e(TAG, "failed to generate bearer token", e);
        }
    }
}
