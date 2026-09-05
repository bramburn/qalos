// SPDX-License-Identifier: Apache-2.0
/*
 * qalos — embedded HTTP/JSON server for the Remote Control Service.
 *
 * Bound to 127.0.0.1 by default (see D-004). The auth boundary is the
 * `adb forward` tunnel for v0; LAN exposure requires an explicit
 * configuration change. As a defence-in-depth, every accepted
 * connection must originate from a loopback address.
 *
 * Threading: the listener runs on a dedicated thread (this class).
 * Each accepted connection is handled in its own short-lived thread
 * with a bounded read timeout. The accept loop self-heals: a
 * thrown IOException closes the dead socket, sleeps 1s, and
 * re-binds the listener. After 5 consecutive bind failures the
 * loop gives up and logs at wtf level (port may be held by another
 * process; we cannot free it).
 *
 * The server takes an {@link IRemoteControl} (plain Java interface,
 * same package) and calls it directly. v0 does not publish the
 * service over Binder.
 */

package com.qalos.remotectl;

import android.util.Log;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;

/**
 * Minimal HTTP/JSON front-end for {@link IRemoteControl}. Bounded
 * resources, no streaming responses, no keep-alive — every request is
 * a fresh connection.
 */
public final class HttpApiServer extends Thread {
    private static final String TAG = "QaRemoteCtlHttp";

    /**
     * Maximum request body in bytes. The body is the JSON payload for
     * the small POST endpoints we accept (coordinates, package names,
     * a short text string). 64 KiB is a hard cap; legitimate clients
     * should never need more than 1 KiB. The cap exists to keep a
     * single misbehaving client from wedging the per-connection
     * thread on a large read.
     */
    private static final int MAX_BODY_BYTES = 64 * 1024;

    /** Per-connection socket timeout. */
    private static final int SOCKET_TIMEOUT_MS = 5_000;

    /** Sleep between listener rebinds (ms). */
    private static final long REBIND_BACKOFF_MS = 1_000L;

    /** Hard cap on consecutive rebind failures before we give up. */
    private static final int MAX_REBIND_FAILURES = 5;

    /**
     * The list of endpoint names exposed by this server. Used by
     * /capabilities to advertise what the client may call. Keep in
     * sync with the dispatch in {@link #handle}.
     */
    private static final String[] ENDPOINTS = {
            "health", "display", "screenshot", "foreground",
            "tap", "type", "key", "launch", "force_stop",
            "long_press", "swipe", "pinch",
            "capabilities", "info"
    };

    private final int mPort;
    private final IRemoteControl mService;
    private final boolean mBindLocalOnly;

    private volatile boolean mRunning = true;
    // `mServer` is written in `run()` and read by `shutdown()` from
    // a different thread. `volatile` is the cheapest happens-before
    // fence; `final` after the assignment is not an option because
    // the field is assigned in `run()`, not the constructor.
    private volatile ServerSocket mServer;

    public HttpApiServer(int port, IRemoteControl service, boolean bindLocalOnly) {
        super("qalos-remote-ctl-http");
        mPort = port;
        mService = service;
        mBindLocalOnly = bindLocalOnly;
        // Daemon: a service shutdown must not block system_server
        // waiting for us to drain.
        setDaemon(true);
    }

    public void shutdown() {
        mRunning = false;
        if (mServer != null) {
            try {
                mServer.close();
            } catch (IOException ignored) {
                // shutting down
            }
        }
    }

    @Override
    public void run() {
        int rebindFailures = 0;
        while (mRunning) {
            try {
                mServer = new ServerSocket(
                        mPort,
                        /* backlog */ 16,
                        mBindLocalOnly ? InetAddress.getByName("127.0.0.1") : null);
                Log.i(TAG, "listening on "
                        + (mBindLocalOnly ? "127.0.0.1" : "0.0.0.0") + ":" + mPort);
                rebindFailures = 0; // reset on successful bind
                while (mRunning) {
                    final Socket client = mServer.accept();
                    handleConnection(client);
                }
            } catch (IOException e) {
                if (!mRunning) {
                    // shutdown() called; this is the expected close.
                    break;
                }
                // Listener died mid-run. Close the dead socket, sleep,
                // and re-bind. This is the v0.1 self-heal: previously
                // a single IOException here killed the thread and left
                // port 9000 dead until system_server was restarted.
                Log.e(TAG, "listener failed, will rebind in "
                        + REBIND_BACKOFF_MS + "ms", e);
                closeQuietly(mServer);
                mServer = null;
                rebindFailures++;
                if (rebindFailures > MAX_REBIND_FAILURES) {
                    Log.wtf(TAG, "listener rebind failed "
                            + rebindFailures + " times; giving up", e);
                    break;
                }
                try {
                    Thread.sleep(REBIND_BACKOFF_MS);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        }
        closeQuietly(mServer);
        Log.i(TAG, "listener thread exiting");
    }

    private static void closeQuietly(ServerSocket s) {
        if (s == null) return;
        try { s.close(); } catch (IOException ignored) { }
    }

    private void handleConnection(Socket client) {
        // Each connection gets its own thread. The HTTP server is not a
        // hot path; we do not pool threads in v0.
        Thread t = new Thread(() -> {
            try (Socket socket = client) {
                socket.setSoTimeout(SOCKET_TIMEOUT_MS);
                if (!socket.getInetAddress().isLoopbackAddress()) {
                    // Defence-in-depth: even though we bind to
                    // 127.0.0.1, a future configuration could bind to
                    // 0.0.0.0. Reject any non-loopback client up front.
                    writeError(socket.getOutputStream(), 403,
                            "only loopback clients are accepted");
                    return;
                }
                dispatch(socket);
            } catch (IOException e) {
                // Client disconnect or timeout — silent. The connection
                // is already closed by the try-with-resources.
            }
        }, "qalos-remote-ctl-conn");
        // Catch uncaught throwables (e.g. OOM, AssertionError) so a
        // single bad request does not silently take the connection
        // thread down without a log entry.
        t.setUncaughtExceptionHandler((thr, ex) -> Log.e(TAG,
                "unhandled exception in connection thread", ex));
        t.start();
    }

    private void dispatch(Socket socket) throws IOException {
        final InputStream in = socket.getInputStream();
        final OutputStream out = socket.getOutputStream();

        final String requestLine = readLine(in);
        if (requestLine == null) {
            return;
        }
        final String[] parts = requestLine.split(" ");
        if (parts.length < 3) {
            writeError(out, 400, "malformed request line");
            return;
        }
        if (!parts[2].startsWith("HTTP/")) {
            // RFC 9112 §3 — request-line = method SP request-target SP HTTP-version
            writeError(out, 400, "malformed HTTP version");
            return;
        }
        final String method = parts[0];
        // Split the request-target into path and query string so the
        // GET /screenshot?width=… contract is honoured. The query
        // string is then parsed into a JSONObject and passed to the
        // handler just like a POST body would be.
        final String[] pathAndQuery = _splitPathQuery(parts[1]);
        final String path = pathAndQuery[0];
        final String query = pathAndQuery[1];
        final JSONObject queryParams = _parseQuery(query);

        int contentLength = 0;
        String header;
        while ((header = readLine(in)) != null && !header.isEmpty()) {
            final int colon = header.indexOf(':');
            if (colon > 0
                    && "Content-Length".equalsIgnoreCase(header.substring(0, colon).trim())) {
                try {
                    contentLength = Integer.parseInt(header.substring(colon + 1).trim());
                } catch (NumberFormatException ignored) {
                    writeError(out, 400, "invalid Content-Length");
                    return;
                }
            }
        }
        if (contentLength > MAX_BODY_BYTES) {
            writeError(out, 413, "body too large");
            return;
        }
        final String body = contentLength > 0 ? readBody(in, contentLength) : "";

        try {
            handle(method, path, queryParams, body, out);
        } catch (IllegalArgumentException e) {
            writeError(out, 400, e.getMessage());
        } catch (IllegalStateException e) {
            writeError(out, 503, e.getMessage());
        } catch (UnsupportedOperationException e) {
            // 501 Not Implemented — used for endpoints deferred to v1.
            writeError(out, 501, e.getMessage());
        } catch (JSONException e) {
            // Malformed JSON body or unexpected JSON type — surface as 400
            // so the client can distinguish a bad request from a server bug.
            throw new IllegalArgumentException("invalid JSON: " + e.getMessage(), e);
        } catch (RuntimeException e) {
            // F-2.2: never let a non-IAE/ISE exception kill the
            // per-connection thread silently. The on-device service
            // is a privileged system_server process; visibility is
            // more important than a clean stack trace.
            Log.e(TAG, "handler threw", e);
            try {
                writeError(out, 500, "internal error: " + e.getClass().getSimpleName());
            } catch (IOException ignored) {
                // The client may have hung up; nothing to do.
            }
        }
    }

    private void handle(String method, String path, JSONObject query,
            String body, OutputStream out) throws IOException, JSONException {
        try {
            switch (method + " " + path) {
                case "GET /health":
                    handleHealth(out);
                    return;
                case "GET /display":
                    handleDisplay(out);
                    return;
                case "GET /screenshot":
                    // F-2.1: query parameters carry width/height/quality/display
                    handleScreenshot(query, out);
                    return;
                case "GET /foreground":
                    handleForeground(out);
                    return;
                case "GET /capabilities":
                    handleCapabilities(out);
                    return;
                case "GET /info":
                    handleInfo(out);
                    return;
            }
            if ("POST".equals(method) && path.equals("/tap")) {
                handleTap(parseJson(body), out);
                return;
            }
            if ("POST".equals(method) && path.equals("/type")) {
                handleType(parseJson(body), out);
                return;
            }
            if ("POST".equals(method) && path.equals("/key")) {
                handleKey(parseJson(body), out);
                return;
            }
            if ("POST".equals(method) && path.equals("/launch")) {
                handleLaunch(parseJson(body), out);
                return;
            }
            if ("POST".equals(method) && path.equals("/force_stop")) {
                handleForceStop(parseJson(body), out);
                return;
            }
            if ("POST".equals(method) && path.equals("/long_press")) {
                handleLongPress(parseJson(body), out);
                return;
            }
            if ("POST".equals(method) && path.equals("/swipe")) {
                handleSwipe(parseJson(body), out);
                return;
            }
            if ("POST".equals(method) && path.equals("/pinch")) {
                handlePinch(parseJson(body), out);
                return;
            }
            writeError(out, 404, "no such endpoint");
        } catch (JSONException e) {
            // Malformed JSON body or unexpected JSON type — surface as 400
            // so the client can distinguish a bad request from a server bug.
            throw new IllegalArgumentException("invalid JSON: " + e.getMessage(), e);
        }
    }

    // ------------------------------------------------------------------
    // Endpoint handlers
    // ------------------------------------------------------------------

    private void handleHealth(OutputStream out) throws IOException {
        final JSONObject json = new JSONObject();
        try {
            json.put("status", "ok");
            // Do not leak Build.FINGERPRINT (it contains the device
            // serial-equivalent identifier). The client knows which
            // device it is talking to; a static service identifier is
            // enough.
            json.put("service", "qalos-remote-control");
            json.put("android", android.os.Build.VERSION.RELEASE);
        } catch (JSONException impossible) {
            // JSONObject.put only throws on non-JSON-serialisable keys
            // (String). The keys above are constants.
        }
        writeJson(out, 200, json);
    }

    private void handleDisplay(OutputStream out)
            throws IOException, JSONException {
        final int displayId = 0; // query on default display
        final JSONObject json = new JSONObject();
        json.put("width", mService.getDisplayWidth(displayId));
        json.put("height", mService.getDisplayHeight(displayId));
        writeJson(out, 200, json);
    }

    private void handleScreenshot(JSONObject body, OutputStream out)
            throws IOException, JSONException {
        final int width = body.optInt("width", 0);
        final int height = body.optInt("height", 0);
        final int quality = body.optInt("quality", 85);
        final int displayId = body.optInt("display", 0);
        final String b64 = mService.screenshotBase64(width, height, displayId, quality);
        final JSONObject json = new JSONObject();
        json.put("image", b64);
        // Report the requested (effective) capture size, not the
        // input — the client wants to know what was actually captured.
        json.put("width", width);
        json.put("height", height);
        json.put("format", "png");
        writeJson(out, 200, json);
    }

    private void handleForeground(OutputStream out)
            throws IOException, JSONException {
        final String pkg = mService.getForegroundPackage();
        final JSONObject json = new JSONObject();
        json.put("package", pkg);
        writeJson(out, 200, json);
    }

    private void handleTap(JSONObject body, OutputStream out)
            throws IOException, JSONException {
        requireInt(body, "x");
        requireInt(body, "y");
        final int x = body.getInt("x");
        final int y = body.getInt("y");
        final int displayId = body.optInt("display", 0);
        mService.tap(x, y, displayId);
        writeOk(out);
    }

    private void handleType(JSONObject body, OutputStream out)
            throws IOException, JSONException {
        requireString(body, "text");
        mService.typeText(body.getString("text"));
        writeOk(out);
    }

    private void handleKey(JSONObject body, OutputStream out)
            throws IOException, JSONException {
        requireInt(body, "key_code");
        final int code = body.getInt("key_code");
        final boolean down = body.optBoolean("down", true);
        mService.keyEvent(code, down);
        writeOk(out);
    }

    private void handleLaunch(JSONObject body, OutputStream out)
            throws IOException, JSONException {
        requireString(body, "package");
        mService.launchApp(body.getString("package"));
        writeOk(out);
    }

    private void handleForceStop(JSONObject body, OutputStream out)
            throws IOException, JSONException {
        requireString(body, "package");
        mService.forceStop(body.getString("package"));
        writeOk(out);
    }

    private void handleLongPress(JSONObject body, OutputStream out)
            throws IOException, JSONException {
        requireInt(body, "x");
        requireInt(body, "y");
        requireInt(body, "duration_ms");
        final int x = body.getInt("x");
        final int y = body.getInt("y");
        final int durationMs = body.getInt("duration_ms");
        final int displayId = body.optInt("display", 0);
        mService.longPress(x, y, durationMs, displayId);
        writeOk(out);
    }

    private void handleSwipe(JSONObject body, OutputStream out)
            throws IOException, JSONException {
        requireInt(body, "x1");
        requireInt(body, "y1");
        requireInt(body, "x2");
        requireInt(body, "y2");
        requireInt(body, "steps");
        requireInt(body, "duration_ms");
        final int x1 = body.getInt("x1");
        final int y1 = body.getInt("y1");
        final int x2 = body.getInt("x2");
        final int y2 = body.getInt("y2");
        final int steps = body.getInt("steps");
        final int durationMs = body.getInt("duration_ms");
        final int displayId = body.optInt("display", 0);
        mService.swipe(x1, y1, x2, y2, steps, durationMs, displayId);
        writeOk(out);
    }

    private void handlePinch(JSONObject body, OutputStream out)
            throws IOException, JSONException {
        requireInt(body, "cx");
        requireInt(body, "cy");
        requireInt(body, "r1");
        requireInt(body, "r2");
        requireInt(body, "steps");
        requireInt(body, "duration_ms");
        final int cx = body.getInt("cx");
        final int cy = body.getInt("cy");
        final int r1 = body.getInt("r1");
        final int r2 = body.getInt("r2");
        final int steps = body.getInt("steps");
        final int durationMs = body.getInt("duration_ms");
        final int displayId = body.optInt("display", 0);
        mService.pinch(cx, cy, r1, r2, steps, durationMs, displayId);
        writeOk(out);
    }

    private void handleCapabilities(OutputStream out)
            throws IOException {
        final ServiceInfo info = mService.getServiceInfo();
        final JSONObject json = new JSONObject();
        try {
            json.put("service", "qalos-remote-control");
            json.put("service_version", info.serviceVersion);
            json.put("api_version", info.apiVersion);
            json.put("build_id", info.buildId);
            json.put("started_at", info.startedAtEpochMs);
            json.put("uptime_ms", info.uptimeMs);
            // JSON arrays in org.json require a typed put; cast to a
            // generic Object[] and let the library serialize.
            json.put("endpoints", joinEndpoints());
        } catch (JSONException impossible) {
            // keys are constants
        }
        writeJson(out, 200, json);
    }

    private void handleInfo(OutputStream out)
            throws IOException {
        final DeviceInfo info = mService.getDeviceInfo();
        final JSONObject json = new JSONObject();
        try {
            json.put("manufacturer", info.manufacturer);
            json.put("model", info.model);
            json.put("android_release", info.androidRelease);
            json.put("android_sdk", info.androidSdk);
            json.put("display_width", info.displayWidth);
            json.put("display_height", info.displayHeight);
            json.put("foreground_package", info.foregroundPackage);
        } catch (JSONException impossible) {
            // keys are constants
        }
        writeJson(out, 200, json);
    }

    /** Adapt {@link #ENDPOINTS} (String[]) to Object[] for JSONObject. */
    private static Object joinEndpoints() {
        final Object[] out = new Object[ENDPOINTS.length];
        for (int i = 0; i < ENDPOINTS.length; i++) out[i] = ENDPOINTS[i];
        return out;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static String _stripQuery(String path) {
        final int q = path.indexOf('?');
        return q < 0 ? path : path.substring(0, q);
    }

    /**
     * Split a request-target like {@code /screenshot?width=300&height=200}
     * into {@code ["/screenshot", "width=300&height=200"]}.
     */
    private static String[] _splitPathQuery(String requestTarget) {
        final int q = requestTarget.indexOf('?');
        if (q < 0) {
            return new String[] { requestTarget, "" };
        }
        return new String[] {
                requestTarget.substring(0, q),
                requestTarget.substring(q + 1)
        };
    }

    /**
     * Parse a URL-encoded query string into a JSONObject. Values that
     * are not valid JSON numbers/booleans are kept as strings (the
     * endpoint handlers know whether each field is int/bool/string).
     */
    private static JSONObject _parseQuery(String query) {
        final JSONObject out = new JSONObject();
        if (query == null || query.isEmpty()) {
            return out;
        }
        for (final String pair : query.split("&")) {
            if (pair.isEmpty()) {
                continue;
            }
            final int eq = pair.indexOf('=');
            final String rawKey = eq < 0 ? pair : pair.substring(0, eq);
            final String rawVal = eq < 0 ? "" : pair.substring(eq + 1);
            final String key = java.net.URLDecoder.decode(
                    rawKey, java.nio.charset.StandardCharsets.UTF_8);
            final String val = java.net.URLDecoder.decode(
                    rawVal, java.nio.charset.StandardCharsets.UTF_8);
            // Try int, then bool, then string — matches the JSON parser
            // behaviour for endpoint handlers. JSONObject.put(String, Object)
            // declares JSONException but never throws for String keys; the
            // three catches below exist to satisfy the compiler.
            try {
                out.put(key, Integer.parseInt(val));
            } catch (NumberFormatException notInt) {
                if (val.equals("true") || val.equals("false")) {
                    try {
                        out.put(key, Boolean.parseBoolean(val));
                    } catch (JSONException impossible) {
                        // key is a String — JSONObject.put never throws
                        // for String keys.
                    }
                } else {
                    try {
                        out.put(key, val);
                    } catch (JSONException impossible) {
                        // key is a String — JSONObject.put never throws
                        // for String keys.
                    }
                }
            } catch (JSONException impossible) {
                // key is a String — JSONObject.put never throws for
                // String keys.
            }
        }
        return out;
    }

    private static JSONObject parseJson(String body) {
        if (body.isEmpty()) {
            throw new IllegalArgumentException("missing JSON body");
        }
        try {
            return new JSONObject(body);
        } catch (JSONException e) {
            throw new IllegalArgumentException("invalid JSON: " + e.getMessage());
        }
    }

    private static void requireInt(JSONObject body, String key) {
        if (!body.has(key)) {
            throw new IllegalArgumentException("missing field: " + key);
        }
        // optInt would silently default to 0; we want to reject if
        // the field is present but not a number.
        final Object v = body.opt(key);
        if (!(v instanceof Integer) && !(v instanceof Long)) {
            throw new IllegalArgumentException("field not an integer: " + key);
        }
    }

    private static void requireString(JSONObject body, String key) {
        if (!body.has(key)) {
            throw new IllegalArgumentException("missing field: " + key);
        }
        if (!(body.opt(key) instanceof String)) {
            throw new IllegalArgumentException("field not a string: " + key);
        }
    }

    private static void writeOk(OutputStream out) throws IOException {
        writeJson(out, 200, okJson());
    }

    private static JSONObject okJson() {
        final JSONObject json = new JSONObject();
        try {
            json.put("status", "ok");
        } catch (JSONException impossible) {
            // see handleHealth
        }
        return json;
    }

    private static void writeJson(OutputStream out, int status, JSONObject body)
            throws IOException {
        final byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
        final String statusText = statusText(status);
        final String headers = "HTTP/1.1 " + status + " " + statusText + "\r\n"
                + "Content-Type: application/json; charset=utf-8\r\n"
                + "Content-Length: " + payload.length + "\r\n"
                + "Connection: close\r\n"
                + "\r\n";
        out.write(headers.getBytes(StandardCharsets.US_ASCII));
        out.write(payload);
        out.flush();
    }

    private static void writeError(OutputStream out, int status, String message)
            throws IOException {
        final JSONObject json = new JSONObject();
        try {
            json.put("status", "error");
            json.put("message", message);
        } catch (JSONException impossible) {
            // see handleHealth
        }
        writeJson(out, status, json);
    }

    private static String statusText(int status) {
        switch (status) {
            case 200: return "OK";
            case 400: return "Bad Request";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 413: return "Payload Too Large";
            case 500: return "Internal Server Error";
            case 501: return "Not Implemented";
            case 503: return "Service Unavailable";
            default:  return "Status";
        }
    }

    private static String readLine(InputStream in) throws IOException {
        final ByteArrayOutputStream buf = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') {
                if (buf.size() > 0 && buf.toByteArray()[buf.size() - 1] == '\r') {
                    buf.write(c);
                    return buf.toString(StandardCharsets.UTF_8).trim();
                }
                return buf.toString(StandardCharsets.UTF_8).trim();
            }
            buf.write(c);
        }
        return null;
    }

    private static String readBody(InputStream in, int contentLength) throws IOException {
        final byte[] data = new byte[contentLength];
        int read = 0;
        while (read < contentLength) {
            int n = in.read(data, read, contentLength - read);
            if (n < 0) {
                throw new IOException("unexpected EOF in body");
            }
            read += n;
        }
        return new String(data, StandardCharsets.UTF_8);
    }
}
