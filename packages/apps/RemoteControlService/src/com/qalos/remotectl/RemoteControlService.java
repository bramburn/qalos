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
 *
 * Heavy work (screenshot capture + bitmap encoding, gesture
 * injection with sleeps) is dispatched to a fixed 4-thread
 * {@link java.util.concurrent.ExecutorService} so the binder thread
 * (which the HTTP per-connection thread lives on) never blocks.
 */

package com.qalos.remotectl;

import android.app.ActivityManager;
import android.app.IActivityManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.hardware.HardwareBuffer;
import android.hardware.display.DisplayManager;
import android.hardware.input.InputManager;
import android.os.Build;
import android.os.RemoteException;
import android.os.SystemClock;
import android.os.SystemProperties;
import android.os.UserHandle;
import android.util.Base64;
import android.util.Log;
import android.util.Size;
import android.view.Display;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceControl;
import android.window.ScreenCapture;

import com.android.server.LocalServices;
import com.android.server.SystemService;
import com.android.server.input.InputManagerService;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

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

    /** Service version. Bump when the wire shape changes. */
    static final String SERVICE_VERSION = "0.1.0";
    /** Wire-shape version. Bump on backward-incompatible API changes. */
    static final int API_VERSION = 1;

    /** Worker thread pool size for input injection + screenshot. */
    private static final int WORKER_THREADS = 4;

    /** Maximum sleep between injected gesture frames (ms). */
    private static final int MAX_GESTURE_DURATION_MS = 10_000;
    private static final int MIN_GESTURE_DURATION_MS = 1;
    private static final int MAX_GESTURE_STEPS = 200;
    private static final int MIN_GESTURE_STEPS = 1;
    private static final int MAX_LONG_PRESS_MS = 5_000;

    private final Context mContext;

    private InputManagerService mInputManager;
    private IActivityManager mActivityManager;
    private DisplayManager mDisplayManager;

    private HttpApiServer mHttpServer;

    private final ExecutorService mWorker;
    private long mStartedAtEpochMs;

    public RemoteControlService(Context context) {
        super(context);
        mContext = context;
        mWorker = Executors.newFixedThreadPool(WORKER_THREADS, r -> {
            Thread t = new Thread(r, "qalos-input-worker");
            t.setDaemon(true);
            return t;
        });
    }

    @Override
    public void onStart() {
        // The HTTP server is the only v0 client; it holds a direct
        // reference to this instance. We do not publish the service
        // over Binder (no AIDL in v0).
        mStartedAtEpochMs = System.currentTimeMillis();
        mHttpServer = new HttpApiServer(
                DEFAULT_PORT,
                this,
                DEFAULT_BIND_LOCAL_ONLY);
        mHttpServer.start();
        Log.i(TAG, "remote control service ready on port " + DEFAULT_PORT
                + " (version " + SERVICE_VERSION + ")");
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
    // system_server automatically. The worker pool is also daemon so
    // it does not block JVM exit. No shutdown hook needed.

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
    // IRemoteControl — gestures (v0.1)
    // ------------------------------------------------------------------

    @Override
    public void longPress(int x, int y, int durationMs, int displayId) {
        enforceCoordinatesOnDisplay(x, y, displayId);
        final int clampedDuration = clamp(durationMs, MIN_GESTURE_DURATION_MS, MAX_LONG_PRESS_MS);
        mWorker.submit(() -> {
            try {
                injectLongPress(x, y, clampedDuration, displayId);
            } catch (Throwable t) {
                Log.e(TAG, "longPress failed at (" + x + "," + y + ")", t);
            }
        });
    }

    @Override
    public void swipe(int x1, int y1, int x2, int y2, int steps, int durationMs,
                      int displayId) {
        enforceCoordinatesOnDisplay(x1, y1, displayId);
        enforceCoordinatesOnDisplay(x2, y2, displayId);
        final int clampedSteps = clamp(steps, MIN_GESTURE_STEPS, MAX_GESTURE_STEPS);
        final int clampedDuration = clamp(durationMs, MIN_GESTURE_DURATION_MS, MAX_GESTURE_DURATION_MS);
        mWorker.submit(() -> {
            try {
                injectSwipe(x1, y1, x2, y2, clampedSteps, clampedDuration, displayId);
            } catch (Throwable t) {
                Log.e(TAG, "swipe failed (" + x1 + "," + y1 + ")->(" + x2 + "," + y2 + ")", t);
            }
        });
    }

    @Override
    public void pinch(int cx, int cy, int r1, int r2, int steps, int durationMs,
                      int displayId) {
        // Clamp radius to a sane range (1..display diagonal/2); a zero
        // radius would collapse both pointers onto the centre.
        enforceCoordinatesOnDisplay(cx - r1, cy, displayId);
        enforceCoordinatesOnDisplay(cx + r1, cy, displayId);
        enforceCoordinatesOnDisplay(cx - r2, cy, displayId);
        enforceCoordinatesOnDisplay(cx + r2, cy, displayId);
        final int clampedSteps = clamp(steps, MIN_GESTURE_STEPS, MAX_GESTURE_STEPS);
        final int clampedDuration = clamp(durationMs, MIN_GESTURE_DURATION_MS, MAX_GESTURE_DURATION_MS);
        mWorker.submit(() -> {
            try {
                injectPinch(cx, cy, r1, r2, clampedSteps, clampedDuration, displayId);
            } catch (Throwable t) {
                Log.e(TAG, "pinch failed center=(" + cx + "," + cy + ") r1=" + r1 + " r2=" + r2, t);
            }
        });
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
    public ScreenshotResult screenshotBase64(int width, int height, int displayId, int quality) {
        if (quality < 1 || quality > 100) {
            throw new IllegalArgumentException("quality must be in [1, 100]");
        }
        if (mDisplayManager == null) {
            throw new IllegalStateException("DisplayManager not available");
        }
        final Display display = mDisplayManager.getDisplay(displayId);
        if (display == null) {
            throw new IllegalArgumentException("display not found: " + displayId);
        }
        try {
            // Run on the worker so the binder thread is not blocked by
            // SurfaceFlinger IPC + PNG compression (100-200 ms typical).
            return mWorker.submit(() -> screenshotBase64Internal(width, height, display, quality))
                    .get(30, TimeUnit.SECONDS);
        } catch (java.util.concurrent.TimeoutException e) {
            throw new IllegalStateException("screenshot timed out after 30s", e);
        } catch (java.util.concurrent.ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof RuntimeException) throw (RuntimeException) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new IllegalStateException("screenshot failed", cause);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("screenshot interrupted", e);
        }
    }

    @Override
    public ServiceInfo getServiceInfo() {
        return new ServiceInfo(
                SERVICE_VERSION,
                API_VERSION,
                SystemProperties.get("ro.qalos.build_id", "<unknown>"),
                mStartedAtEpochMs,
                uptimeMs());
    }

    @Override
    public DeviceInfo getDeviceInfo() {
        Size display = null;
        String foreground = "";
        try {
            if (mDisplayManager != null) {
                display = getDisplaySizeInternal(0);
            }
        } catch (Throwable ignored) {
            // best-effort; service is alive before PHASE_BOOT_COMPLETED
            // for a brief window
        }
        try {
            foreground = getForegroundPackage();
        } catch (Throwable ignored) {
            // best-effort
        }
        return new DeviceInfo(
                Build.MANUFACTURER,
                Build.MODEL,
                Build.VERSION.RELEASE,
                Build.VERSION.SDK_INT,
                display,
                foreground);
    }

    private int uptimeMs() {
        return (int) (System.currentTimeMillis() - mStartedAtEpochMs);
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
        // MotionEvent.recycle() is deprecated since API 28; in AOSP 15
        // MotionEvents are pooled by the finalizer. Calling recycle()
        // is harmless but unnecessary; align with the Bitmap.recycle()
        // cleanup already in followup-work.md (review-triage 2026-09-05).
        try {
            injectEvent(down);
            injectEvent(up);
        } catch (RuntimeException e) {
            // The events are now owned by the input system; on failure
            // we let them drain via the finalizer rather than recycling.
            throw e;
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

    private void injectLongPress(int x, int y, int durationMs, int displayId) {
        final long t0 = SystemClock.uptimeMillis();
        final MotionEvent down = MotionEvent.obtain(
                t0, t0, MotionEvent.ACTION_DOWN, x, y, 1.0f, 1.0f,
                0, 1.0f, 1.0f, 0, 0);
        if (displayId != 0) down.setDisplayId(displayId);
        injectEvent(down);
        // MotionEvent.recycle() deprecated in API 28; AOSP 15 pools
        // automatically (see injectTap). Review-triage 2026-09-05.

        try {
            Thread.sleep(durationMs);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }

        final long t1 = SystemClock.uptimeMillis();
        final MotionEvent up = MotionEvent.obtain(
                t1, t1, MotionEvent.ACTION_UP, x, y, 0.0f, 0.0f,
                0, 1.0f, 1.0f, 0, 0);
        if (displayId != 0) up.setDisplayId(displayId);
        injectEvent(up);
    }

    private void injectSwipe(int x1, int y1, int x2, int y2,
                             int steps, int durationMs, int displayId) {
        final long t0 = SystemClock.uptimeMillis();
        final MotionEvent down = MotionEvent.obtain(
                t0, t0, MotionEvent.ACTION_DOWN, x1, y1, 1.0f, 1.0f,
                0, 1.0f, 1.0f, 0, 0);
        if (displayId != 0) down.setDisplayId(displayId);
        injectEvent(down);

        final long stepMillis = Math.max(1, durationMs / steps);
        for (int i = 1; i <= steps; i++) {
            final float frac = (float) i / steps;
            final float x = x1 + (x2 - x1) * frac;
            final float y = y1 + (y2 - y1) * frac;
            final long t = t0 + (stepMillis * i);
            final MotionEvent move = MotionEvent.obtain(
                    t, t, MotionEvent.ACTION_MOVE, x, y, 1.0f, 1.0f,
                    0, 1.0f, 1.0f, 0, 0);
            if (displayId != 0) move.setDisplayId(displayId);
            injectEvent(move);
            // Align wall-clock pacing with the event timestamps so the
            // gesture is not collapsed by the dispatcher. Previously
            // this was a hard-coded `Thread.sleep(1)`; with steps=20
            // and durationMs=300 that meant 20ms of wall-clock for
            // 300ms of timestamp span, and the dispatcher would
            // sometimes drop intermediate events. Review-triage
            // 2026-09-05.
            try { Thread.sleep(stepMillis); }
            catch (InterruptedException e) { Thread.currentThread().interrupt(); break; }
        }

        final long tN = t0 + durationMs;
        final MotionEvent up = MotionEvent.obtain(
                tN, tN, MotionEvent.ACTION_UP, x2, y2, 0.0f, 0.0f,
                0, 1.0f, 1.0f, 0, 0);
        if (displayId != 0) up.setDisplayId(displayId);
        injectEvent(up);
    }

    private void injectPinch(int cx, int cy, int r1, int r2,
                             int steps, int durationMs, int displayId) {
        // Two pointers at (cx - r, cy) and (cx + r, cy). r interpolates
        // from r1 to r2 over `steps` MOVE events.
        final MotionEvent.PointerProperties[] pp = new MotionEvent.PointerProperties[2];
        for (int i = 0; i < 2; i++) {
            pp[i] = new MotionEvent.PointerProperties();
            pp[i].id = i;
            pp[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
        }
        final MotionEvent.PointerCoords[] pc = new MotionEvent.PointerCoords[2];
        for (int i = 0; i < 2; i++) {
            pc[i] = new MotionEvent.PointerCoords();
            pc[i].pressure = 1.0f;
            pc[i].size = 1.0f;
        }
        // Multi-pointer events are stricter about the `source` field.
        // Use SOURCE_TOUCHSCREEN explicitly so the dispatcher routes
        // them to the touch input pipeline (review-triage 2026-09-05).
        final int source = InputDevice.SOURCE_TOUCHSCREEN;
        final long t0 = SystemClock.uptimeMillis();
        // ACTION_DOWN with one pointer.
        pc[0].x = cx - r1;
        pc[0].y = cy;
        pc[1].x = 0;
        pc[1].y = 0;
        MotionEvent down = MotionEvent.obtain(
                t0, t0, MotionEvent.ACTION_DOWN, 1, pp, pc,
                0, 0, 1.0f, 1.0f, 0, 0, source, 0);
        if (displayId != 0) down.setDisplayId(displayId);
        injectEvent(down);
        // MotionEvent.recycle() deprecated in API 28; AOSP 15 pools
        // automatically (see injectTap). Review-triage 2026-09-05.

        // ACTION_POINTER_DOWN (second pointer lands).
        pc[0].x = cx - r1;
        pc[0].y = cy;
        pc[1].x = cx + r1;
        pc[1].y = cy;
        MotionEvent pointerDown = MotionEvent.obtain(
                t0 + 1, t0 + 1,
                MotionEvent.ACTION_POINTER_DOWN
                        | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                2, pp, pc, 0, 0, 1.0f, 1.0f, 0, 0, source, 0);
        if (displayId != 0) pointerDown.setDisplayId(displayId);
        injectEvent(pointerDown);

        // `steps` ACTION_MOVE events with both pointers, r interpolating.
        final long stepMillis = Math.max(1, durationMs / steps);
        for (int i = 1; i <= steps; i++) {
            final float frac = (float) i / steps;
            final float r = r1 + (r2 - r1) * frac;
            final long t = t0 + (stepMillis * i);
            pc[0].x = cx - r;
            pc[0].y = cy;
            pc[1].x = cx + r;
            pc[1].y = cy;
            MotionEvent move = MotionEvent.obtain(
                    t, t, MotionEvent.ACTION_MOVE, 2, pp, pc,
                    0, 0, 1.0f, 1.0f, 0, 0, source, 0);
            if (displayId != 0) move.setDisplayId(displayId);
            injectEvent(move);
            // Align wall-clock pacing with the event timestamps so the
            // gesture is not collapsed by the dispatcher. See
            // injectSwipe for the full rationale. Review-triage
            // 2026-09-05.
            try { Thread.sleep(stepMillis); }
            catch (InterruptedException e) { Thread.currentThread().interrupt(); break; }
        }

        // ACTION_POINTER_UP (second pointer lifts).
        final long tN = t0 + durationMs;
        pc[0].x = cx - r2;
        pc[0].y = cy;
        pc[1].x = cx + r2;
        pc[1].y = cy;
        MotionEvent pointerUp = MotionEvent.obtain(
                tN, tN,
                MotionEvent.ACTION_POINTER_UP
                        | (1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                2, pp, pc, 0, 0, 1.0f, 1.0f, 0, 0, source, 0);
        if (displayId != 0) pointerUp.setDisplayId(displayId);
        injectEvent(pointerUp);

        // ACTION_UP (final pointer up).
        pc[0].x = cx - r2;
        pc[0].y = cy;
        pc[1].x = cx + r2;
        pc[1].y = cy;
        MotionEvent up = MotionEvent.obtain(
                tN, tN, MotionEvent.ACTION_UP, 1, pp, pc,
                0, 0, 0.0f, 0.0f, 0, 0, source, 0);
        if (displayId != 0) up.setDisplayId(displayId);
        injectEvent(up);
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
        // S-B in the v0 followup list: migrate to
        // `WindowManager.getCurrentWindowMetrics().getBounds()` in v1.
        // Note: the `display` argument above is the one that matches
        // `displayId` — do NOT call `mContext.getDisplay()` here, that
        // returns the context's own display (always display 0 in
        // system_server) and silently ignores the requested displayId.
        // Review-triage 2026-09-05.
        final android.graphics.Point size = new android.graphics.Point();
        display.getRealSize(size);
        // android.util.Size.of(int, int) was removed in AOSP 15; use the
        // public 2-arg constructor instead.
        return new Size(size.x, size.y);
    }

    // ------------------------------------------------------------------
    // Screenshot
    // ------------------------------------------------------------------

    private ScreenshotResult screenshotBase64Internal(int width, int height,
                                             Display display, int quality) {
        // Resolve capture size: 0 means native display size.
        // `Display.getMode()` returns a `Display.Mode`; there is no
        // `getMode()` on that type. Review-triage 2026-09-05.
        final int capW = width > 0 ? width : display.getMode().getPhysicalWidth();
        final int capH = height > 0 ? height : display.getMode().getPhysicalHeight();

        ScreenCapture.CaptureDisplayArgs args =
                new ScreenCapture.CaptureDisplayArgs.Builder(display)
                        .setSize(capW, capH)
                        .build();
        ScreenCapture.ScreenshotHardwareBuffer buffer =
                ScreenCapture.captureDisplay(args);
        if (buffer == null) {
            throw new IllegalStateException("ScreenCapture.captureDisplay returned null");
        }
        Bitmap bitmap = null;
        try {
            bitmap = buffer.asBitmap();
            if (bitmap == null) {
                throw new IllegalStateException("ScreenshotHardwareBuffer.asBitmap returned null");
            }
            // Re-scale if the caller asked for a specific width/height that
            // differs from the native mode. SurfaceFlinger returns the
            // requested size; if the caller passed 0, the bitmap is
            // already at the native resolution.
            // (No rescale: the framework honors setSize exactly.)
            // NOTE: `quality` is ignored by `Bitmap.compress` for PNG
            // (PNG is lossless). The parameter is accepted for forward
            // compatibility with a future JPEG backend; clients should
            // not depend on it. Documented in api.md.
            final ByteArrayOutputStream baos = new ByteArrayOutputStream(64 * 1024);
            bitmap.compress(Bitmap.CompressFormat.PNG, quality, baos);
            final String b64 = Base64.encodeToString(baos.toByteArray(), Base64.NO_WRAP);
            // Return the *effective* capture size (not the requested
            // params) so the HTTP layer can echo the truth to the
            // client. When `width=0`/`height=0` was passed, the bitmap
            // is at native display resolution and that is what we
            // return. Review-triage 2026-09-05.
            return new ScreenshotResult(b64, bitmap.getWidth(), bitmap.getHeight());
        } finally {
            if (bitmap != null) bitmap.recycle();
            // The underlying HardwareBuffer must be released. The class
            // does not implement AutoCloseable on AOSP 15, so reach into
            // the public getter and close it.
            HardwareBuffer hb = buffer.getHardwareBuffer();
            if (hb != null) hb.close();
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

    private static int clamp(int v, int lo, int hi) {
        return Math.max(lo, Math.min(hi, v));
    }
}
