// SPDX-License-Identifier: Apache-2.0
/*
 * qalos — embedded HTTP/JSON server for the Remote Control Service.
 *
 * Bound to 127.0.0.1 by default (see D-004). The auth boundary is the
 * `adb forward` tunnel for v0; LAN exposure requires an explicit
 * configuration change. As a defence-in-depth, every accepted
 * connection must originate from a loopback address.
 *
 * Threading: the listener runs on a dedicated thread. Each accepted
 * connection is handled in its own short-lived thread with a bounded
 * read timeout.
 */

package com.qalos.remotectl;

import android.os.IRemoteControl;
import android.os.RemoteException;
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

    private final int mPort;
    private final IRemoteControl mService;
    private final boolean mBindLocalOnly;

    private volatile boolean mRunning = true;
    private ServerSocket mServer;

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
        if (parts.length < 2) {
            writeError(out, 400, "malformed request line");
            return;
        }
        final String method = parts[0];
        // Strip the query string so `GET /screenshot?width=0` matches
        // the `GET /screenshot` case in the switch below.
        final String path = _stripQuery(parts[1]);

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
            handle(method, path, body, out);
        } catch (IllegalArgumentException e) {
            writeError(out, 400, e.getMessage());
        } catch (IllegalStateException e) {
            writeError(out, 503, e.getMessage());
        } catch (RemoteException e) {
            writeError(out, 500, "binder error");
        }
    }

    private void handle(String method, String path, String body, OutputStream out)
            throws IOException, RemoteException {
        switch (method + " " + path) {
            case "GET /health":
                handleHealth(out);
                return;
            case "GET /display":
                handleDisplay(out);
                return;
            case "GET /screenshot":
                handleScreenshot(new JSONObject(), out);
                return;
            case "GET /foreground":
                handleForeground(out);
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
        writeError(out, 404, "no such endpoint");
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

    private void handleDisplay(OutputStream out) throws IOException, RemoteException {
        final int displayId = 0; // query on default display
        final JSONObject json = new JSONObject();
        json.put("width", mService.getDisplayWidth(displayId));
        json.put("height", mService.getDisplayHeight(displayId));
        writeJson(out, 200, json);
    }

    private void handleScreenshot(JSONObject body, OutputStream out)
            throws IOException, RemoteException {
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

    private void handleForeground(OutputStream out) throws IOException, RemoteException {
        final String pkg = mService.getForegroundPackage();
        final JSONObject json = new JSONObject();
        json.put("package", pkg);
        writeJson(out, 200, json);
    }

    private void handleTap(JSONObject body, OutputStream out)
            throws IOException, RemoteException {
        requireInt(body, "x");
        requireInt(body, "y");
        final int x = body.getInt("x");
        final int y = body.getInt("y");
        final int displayId = body.optInt("display", 0);
        mService.tap(x, y, displayId);
        writeOk(out);
    }

    private void handleType(JSONObject body, OutputStream out)
            throws IOException, RemoteException {
        requireString(body, "text");
        mService.typeText(body.getString("text"));
        writeOk(out);
    }

    private void handleKey(JSONObject body, OutputStream out)
            throws IOException, RemoteException {
        requireInt(body, "key_code");
        final int code = body.getInt("key_code");
        final boolean down = body.optBoolean("down", true);
        mService.keyEvent(code, down);
        writeOk(out);
    }

    private void handleLaunch(JSONObject body, OutputStream out)
            throws IOException, RemoteException {
        requireString(body, "package");
        mService.launchApp(body.getString("package"));
        writeOk(out);
    }

    private void handleForceStop(JSONObject body, OutputStream out)
            throws IOException, RemoteException {
        requireString(body, "package");
        mService.forceStop(body.getString("package"));
        writeOk(out);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static String _stripQuery(String path) {
        final int q = path.indexOf('?');
        return q < 0 ? path : path.substring(0, q);
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
            case 503: return "Service Unavailable";
            default:  return "Status";
        }
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
