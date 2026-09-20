// SPDX-License-Identifier: Apache-2.0
/*
 * qalos — embedded HTTP/JSON server for the Remote Control Service.
 *
 * Bound to 127.0.0.1 by default (see D-004). When
 * {@code mBindLocalOnly == false} the server binds to 0.0.0.0 and
 * uses a bearer-token auth scheme for all non-loopback clients. The
 * token is generated once on first boot and stored in
 * {@code /data/local/tmp/qalos_token}. Loopback clients are trusted
 * and skip token auth (same-machine access via adb).
 *
 * Threading: the listener runs on a dedicated thread. Each accepted
 * connection is handled in its own short-lived thread with a bounded
 * read timeout.
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
import java.util.HashMap;
import java.util.Map;

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

    /**
     * Cap on the byte length of the HTTP request-line and each header
     * line read via {@link #readLine}. A malicious or buggy client can
     * send an infinite stream of bytes without a newline; the cap
     * prevents {@code readLine} from accumulating until OOM in that
     * case. 8 KiB is well above any reasonable HTTP/1.1 request-line or
     * header value (RFC 9110 §5.5 recommends a server limit of at least
     * 8 KiB for the request-line alone).
     */
    private static final int MAX_LINE_BYTES = 8 * 1024;

    @FunctionalInterface
    private interface RouteHandler {
        /**
         * Run the handler.
         *
         * @param socket the client connection (handlers usually only need
         *               {@code socket.getOutputStream()})
         * @param body   the parsed request body as a UTF-8 string; empty
         *               string for GET/DELETE without a body
         * @param query  the parsed query string as a JSONObject (URL-decoded;
         *               values parsed as int/bool/string); empty JSONObject if
         *               the request had no query string
         */
        void handle(Socket socket, String body, JSONObject query) throws IOException;
    }

    private static final Map<String, RouteHandler> ROUTES = new HashMap<>();
    static {
        ROUTES.put("GET /health",     (sock, body, query) -> handleHealth(sock.getOutputStream()));
        ROUTES.put("GET /display",   (sock, body, query) -> handleDisplay(sock.getOutputStream()));
        ROUTES.put("GET /screenshot",(sock, body, query) -> handleScreenshot(sock.getOutputStream(), query));
        ROUTES.put("GET /foreground",(sock, body, query) -> handleForeground(sock.getOutputStream()));
        ROUTES.put("POST /tap",       (sock, body, query) -> handleTap(sock.getOutputStream(), body));
        ROUTES.put("POST /type",      (sock, body, query) -> handleType(sock.getOutputStream(), body));
        ROUTES.put("POST /key",       (sock, body, query) -> handleKey(sock.getOutputStream(), body));
        ROUTES.put("POST /launch",    (sock, body, query) -> handleLaunch(sock.getOutputStream(), body));
        ROUTES.put("POST /force_stop",(sock, body, query) -> handleForceStop(sock.getOutputStream(), body));
        ROUTES.put("POST /long_press",(sock, body, query) -> handleLongPress(sock.getOutputStream(), body));
        ROUTES.put("POST /swipe",     (sock, body, query) -> handleSwipe(sock.getOutputStream(), body));
        ROUTES.put("POST /pinch",     (sock, body, query) -> handlePinch(sock.getOutputStream(), body));
    }

    /** Per-connection socket timeout. */
    private static final int SOCKET_TIMEOUT_MS = 5_000;

    private final int mPort;
    private final IRemoteControl mService;
    private final boolean mBindLocalOnly;
    /**
     * Cached bearer token, populated once at construction from the path
     * managed by {@code RemoteControlService.ensureTokenExists()}. {@code null}
     * here means the token file was unreadable at startup — non-loopback
     * requests will all be rejected with 401, which is the safe failure mode.
     * Marked {@code volatile} so the per-connection handler threads see the
     * value without a synchronisation edge (same happens-before fence as
     * {@code mServer}).
     */
    private final String mBearerToken;

    private volatile boolean mRunning = true;
    // `mServer` is written in `run()` and read by `shutdown()` from
    // a different thread. `volatile` is the cheapest happens-before
    // fence; `final` after the assignment is not an option because
    // the field is assigned in `run()`, not the constructor.
    private volatile ServerSocket mServer;

    public HttpApiServer(int port, IRemoteControl service, boolean bindLocalOnly,
            String bearerToken) {
        super("qalos-remote-ctl-http");
        mPort = port;
        mService = service;
        mBindLocalOnly = bindLocalOnly;
        mBearerToken = bearerToken;
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
        try {
            mServer = new ServerSocket(
                    mPort,
                    /* backlog */ 16,
                    mBindLocalOnly ? InetAddress.getByName("127.0.0.1") : null);
            Log.i(TAG, "listening on "
                    + (mBindLocalOnly ? "127.0.0.1" : "0.0.0.0") + ":" + mPort);
            while (mRunning) {
                final Socket client = mServer.accept();
                handleConnection(client);
            }
        } catch (IOException e) {
            if (mRunning) {
                Log.e(TAG, "server error", e);
            }
        }
    }

    private void handleConnection(Socket client) {
        // Each connection gets its own thread. The HTTP server is not a
        // hot path; we do not pool threads in v0.
        new Thread(() -> {
            // AOSP 15's javac is strict about try-with-resources
            // scoping inside lambdas (the catch-block `socket` reference
            // is rejected with "cannot find symbol"). Hoist the socket
            // to a final outside the try and use plain try/finally so
            // both the resource and its name are visible in every branch.
            final Socket socket = client;
            try {
                socket.setSoTimeout(SOCKET_TIMEOUT_MS);
                // Auth flow:
                //  1. mBindLocalOnly == true  → skip token check (loopback-only mode unchanged)
                //  2. loopback client         → skip token check (same-machine, trusted)
                //  3. non-loopback            → require valid Bearer token; checked in dispatch()
                dispatch(socket);
            } catch (IOException e) {
                // Client disconnect or timeout — silent. The connection
                // is already closed by the try-with-resources.
            } catch (IllegalArgumentException e) {
                // Protocol violation (oversized line, malformed
                // method/path, etc.). Best-effort 400 if the
                // connection is still open; silent if it isn't.
                Log.w(TAG, "bad request: " + e.getMessage());
                try {
                    writeErrorJson(socket.getOutputStream(), 400, "BAD_REQUEST",
                            e.getMessage(), null);
                } catch (IOException ignored) {
                    // The client may have hung up; nothing to do.
                }
            } catch (RuntimeException e) {
                // Defence-in-depth: never let a per-connection
                // thread die silently. Without this, a v1+ handler
                // that throws something we did not anticipate (e.g.
                // a new RuntimeException subclass from a future AOSP
                // release) would silently kill the connection thread
                // and log nothing.
                Log.e(TAG, "per-connection thread crashed", e);
                try {
                    writeErrorJson(socket.getOutputStream(), 500, "INTERNAL_ERROR",
                            "internal error: " + e.getClass().getSimpleName(), null);
                } catch (IOException ignored) {
                    // The client may have hung up; nothing to do.
                }
            } finally {
                try {
                    socket.close();
                } catch (IOException ignored) {
                    // Already closed or never opened; nothing to do.
                }
            }
        }, "qalos-remote-ctl-conn").start();
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
            writeErrorJson(out, 400, "BAD_REQUEST", "malformed request line", null);
            return;
        }
        if (!parts[2].startsWith("HTTP/")) {
            // RFC 9112 §3 — request-line = method SP request-target SP HTTP-version
            writeErrorJson(out, 400, "BAD_REQUEST", "malformed HTTP version", null);
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
        String authHeader = null;
        String header;
        while ((header = readLine(in)) != null && !header.isEmpty()) {
            final int colon = header.indexOf(':');
            if (colon > 0
                    && "Content-Length".equalsIgnoreCase(header.substring(0, colon).trim())) {
                try {
                    contentLength = Integer.parseInt(header.substring(colon + 1).trim());
                } catch (NumberFormatException ignored) {
                    writeErrorJson(out, 400, "BAD_REQUEST", "invalid Content-Length", "Content-Length");
                    return;
                }
            }
            if (colon > 0 && "authorization".equalsIgnoreCase(header.substring(0, colon).trim())) {
                authHeader = header.substring(colon + 1).trim();
            }
        }

        // Bearer-token enforcement for non-loopback clients when bound to 0.0.0.0
        if (!mBindLocalOnly && !socket.getInetAddress().isLoopbackAddress()) {
            if (!validateBearerToken(socket.getOutputStream(), authHeader)) {
                return;
            }
        }
        if (contentLength < 0) {
            // Reject negative Content-Length as a protocol violation
            // before `readBody` allocates `new byte[contentLength]`
            // and throws NegativeArraySizeException. RFC 9110 §8.6
            // requires the value to be a non-negative integer.
            writeErrorJson(out, 400, "BAD_REQUEST", "invalid Content-Length", "Content-Length");
            return;
        }
        if (contentLength > MAX_BODY_BYTES) {
            writeErrorJson(out, 413, "PAYLOAD_TOO_LARGE", "body too large", "body");
            return;
        }
        final String body = contentLength > 0 ? readBody(in, contentLength) : "";

        try {
            handle(socket, method, path, queryParams, body);
        } catch (IllegalArgumentException e) {
            writeErrorJson(out, 400, "BAD_REQUEST", e.getMessage(), null);
        } catch (IllegalStateException e) {
            writeErrorJson(out, 503, "SERVICE_UNAVAILABLE", e.getMessage(), null);
        } catch (UnsupportedOperationException e) {
            // 501 Not Implemented — used for endpoints deferred to v1
            // (currently: screenshot — see RemoteControlService.screenshotBase64Internal).
            writeErrorJson(out, 501, "NOT_IMPLEMENTED", e.getMessage(), null);
        } catch (RuntimeException e) {
            // F-2.2: never let a non-IAE/ISE exception kill the
            // per-connection thread silently. The on-device service
            // is a privileged system_server process; visibility is
            // more important than a clean stack trace.
            Log.e(TAG, "handler threw", e);
            try {
                writeErrorJson(out, 500, "INTERNAL_ERROR",
                        "internal error: " + e.getClass().getSimpleName(), null);
            } catch (IOException ignored) {
                // The client may have hung up; nothing to do.
            }
        }
    }

    private void handle(Socket socket, String method, String path, JSONObject query,
            String body) throws IOException {
        String key = method + " " + path;
        RouteHandler handler = ROUTES.get(key);
        if (handler == null) {
            writeErrorJson(socket.getOutputStream(), 404, "NOT_FOUND", "no such endpoint", null);
            return;
        }
        try {
            handler.handle(socket, body, query);
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

    private void handleScreenshot(OutputStream out, JSONObject query)
            throws IOException, JSONException {
        // GET /screenshot?width=N&height=N&display=N&quality=N
        // Params come from the query string, not the request body.
        // (Pre-fix bug: this handler was reading `body`, which is empty
        // for GET, so every screenshot request 400'd with
        // "missing JSON body".)
        final int width = query.optInt("width", 0);
        final int height = query.optInt("height", 0);
        final int quality = query.optInt("quality", 85);
        final int displayId = query.optInt("display", 0);
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

    private void handleTap(OutputStream out, String body)
            throws IOException, JSONException {
        final JSONObject json = parseJson(body);
        requireInt(json, "x");
        requireInt(json, "y");
        final int x = json.getInt("x");
        final int y = json.getInt("y");
        final int displayId = json.optInt("display", 0);
        mService.tap(x, y, displayId);
        writeOk(out);
    }

    private void handleType(OutputStream out, String body)
            throws IOException, JSONException {
        final JSONObject json = parseJson(body);
        requireString(json, "text");
        mService.typeText(json.getString("text"));
        writeOk(out);
    }

    private void handleKey(OutputStream out, String body)
            throws IOException, JSONException {
        final JSONObject json = parseJson(body);
        requireInt(json, "key_code");
        final int code = json.getInt("key_code");
        final boolean down = json.optBoolean("down", true);
        mService.keyEvent(code, down);
        writeOk(out);
    }

    private void handleLaunch(OutputStream out, String body)
            throws IOException, JSONException {
        final JSONObject json = parseJson(body);
        requireString(json, "package");
        mService.launchApp(json.getString("package"));
        writeOk(out);
    }

    private void handleForceStop(OutputStream out, String body)
            throws IOException, JSONException {
        final JSONObject json = parseJson(body);
        requireString(json, "package");
        mService.forceStop(json.getString("package"));
        writeOk(out);
    }

    private void handleLongPress(OutputStream out, String body)
            throws IOException, JSONException {
        final JSONObject json = parseJson(body);
        requireInt(json, "x");
        requireInt(json, "y");
        requireInt(json, "duration_ms");
        final int displayId = json.optInt("display", 0);
        mService.longPress(json.getInt("x"), json.getInt("y"),
                json.getInt("duration_ms"), displayId);
        writeOk(out);
    }

    private void handleSwipe(OutputStream out, String body)
            throws IOException, JSONException {
        final JSONObject json = parseJson(body);
        requireInt(json, "x1");
        requireInt(json, "y1");
        requireInt(json, "x2");
        requireInt(json, "y2");
        requireInt(json, "duration_ms");
        final int displayId = json.optInt("display", 0);
        mService.swipe(json.getInt("x1"), json.getInt("y1"),
                json.getInt("x2"), json.getInt("y2"),
                json.getInt("duration_ms"), displayId);
        writeOk(out);
    }

    private void handlePinch(OutputStream out, String body)
            throws IOException, JSONException {
        final JSONObject json = parseJson(body);
        requireFloat(json, "x");
        requireFloat(json, "y");
        requireFloat(json, "scale");
        requireInt(json, "duration_ms");
        final int displayId = json.optInt("display", 0);
        mService.pinch(
                (float) json.getDouble("x"),
                (float) json.getDouble("y"),
                (float) json.getDouble("scale"),
                json.getInt("duration_ms"),
                displayId);
        writeOk(out);
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

    private static void requireFloat(JSONObject body, String key) {
        if (!body.has(key)) {
            throw new IllegalArgumentException("missing field: " + key);
        }
        // JSONObject.getDouble returns the numeric value; it throws
        // JSONException if the value is not a number. Guard the cast
        // with a has-check above; the getDouble call validates type.
        try {
            body.getDouble(key);
        } catch (JSONException e) {
            throw new IllegalArgumentException("field not a number: " + key);
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

    private static void writeErrorJson(OutputStream out, int status, String code,
            String message, String field) throws IOException {
        final JSONObject json = new JSONObject();
        try {
            json.put("code", code);
            json.put("message", message);
            if (field != null) {
                json.put("field", field);
            }
        } catch (JSONException impossible) {
            // see handleHealth
        }
        writeJson(out, status, json);
    }

    private static String getReason(int status) {
        return switch (status) {
            case 400 -> "Bad Request";
            case 401 -> "Unauthorized";
            case 403 -> "Forbidden";
            case 404 -> "Not Found";
            case 413 -> "Payload Too Large";
            case 501 -> "Not Implemented";
            case 503 -> "Service Unavailable";
            default  -> "Internal Server Error";
        };
    }

    private static String statusText(int status) {
        switch (status) {
            case 200: return "OK";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 413: return "Payload Too Large";
            case 500: return "Internal Server Error";
            case 501: return "Not Implemented";
            case 503: return "Service Unavailable";
            default:  return "Status";
        }
    }

    private boolean validateBearerToken(OutputStream out, String authHeader) throws IOException {
        // The token was read once at construction (see mBearerToken
        // javadoc). If startup failed to read it, every non-loopback
        // request is rejected — the safe failure mode.
        if (mBearerToken == null) {
            writeUnauthorized(out);
            return false;
        }
        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            writeUnauthorized(out);
            return false;
        }
        final String presentedToken = authHeader.substring(7).trim();
        // Constant-time compare: String.equals short-circuits on the first
        // mismatching byte, leaking per-byte timing to a network attacker.
        // MessageDigest.isEqual walks the full byte range regardless of
        // mismatches. For a 64-char hex token the practical risk is low
        // (nanosecond differences over millisecond-scale LAN latency), but
        // the fix is one line and removes the entire class of concern.
        final byte[] presented = presentedToken.getBytes(StandardCharsets.UTF_8);
        final byte[] expected = mBearerToken.getBytes(StandardCharsets.UTF_8);
        if (!java.security.MessageDigest.isEqual(presented, expected)) {
            writeUnauthorized(out);
            return false;
        }
        return true;
    }

    private static void writeUnauthorized(OutputStream out) throws IOException {
        final JSONObject json = new JSONObject();
        try {
            json.put("code", "UNAUTHORIZED");
            json.put("message", "Bearer token required");
            json.put("field", "Authorization");
        } catch (JSONException impossible) {
            // see handleHealth
        }
        writeJson(out, 401, json);
    }

    private static String readLine(InputStream in) throws IOException {
        final ByteArrayOutputStream buf = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) != -1) {
            if (c == '\n') {
                final byte[] data = buf.toByteArray();
                // strip trailing \r
                final int end = (data.length > 0 && data[data.length - 1] == '\r')
                        ? data.length - 1 : data.length;
                return new String(data, 0, end, StandardCharsets.US_ASCII);
            }
            if (buf.size() >= MAX_LINE_BYTES) {
                // Bail before the ByteArrayOutputStream can grow
                // unbounded. The caller treats this as a protocol
                // violation and returns HTTP 400.
                throw new IllegalArgumentException("line exceeds " + MAX_LINE_BYTES + " bytes");
            }
            buf.write(c);
        }
        return buf.size() == 0 ? null : buf.toString(StandardCharsets.US_ASCII);
    }

    private static String readBody(InputStream in, int contentLength) throws IOException {
        final byte[] buf = new byte[contentLength];
        int read = 0;
        while (read < contentLength) {
            final int n = in.read(buf, read, contentLength - read);
            if (n < 0) {
                throw new SocketTimeoutException("body truncated");
            }
            read += n;
        }
        return new String(buf, StandardCharsets.UTF_8);
    }
}
