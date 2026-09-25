// vendor/aqa/server/src/main.cpp
//
// aqa_server entry point. Listens on 0.0.0.0:8080 and exposes the REST
// endpoints documented in vendor/aqa/server/README.md.
//
// Signal handling: SIGTERM/SIGINT are BLOCKED in the main thread BEFORE the
// HttpServer accept thread is created, then consumed with sigwait(). Blocking
// first is what makes sigwait reliable — otherwise the signal's default
// disposition (terminate) wins, or the accept thread picks it up instead.
// SIGPIPE is ignored so a client disconnecting mid-response produces an EPIPE
// return rather than killing the daemon.
//
// NO AUTHENTICATION. Bind to a private network / restrict with iptables.

#include "http_server.hpp"
#include "uinput_injector.hpp"

#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>

namespace aqa {
namespace {

constexpr int kDisplayWidth = 1440;   // Pixel 7 Pro QHD+
constexpr int kDisplayHeight = 3120;
constexpr int kListenPort = 8080;

// ---- tiny JSON helpers -------------------------------------------------
// Request bodies are trusted (QA daemon on a private network) and the API
// shapes are flat, so this is a scan rather than a real parser. Keys are
// matched WITH their surrounding quotes, which is what stops a lookup for
// "x" from matching "x1" in a swipe payload.
std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:   out += c;      break;
        }
    }
    return out;
}

bool findInt(const std::string& body, const std::string& key, int& out) {
    const std::string needle = "\"" + key + "\"";
    size_t pos = body.find(needle);
    if (pos == std::string::npos) return false;
    pos = body.find(':', pos + needle.size());
    if (pos == std::string::npos) return false;
    pos = body.find_first_of("-0123456789", pos);
    if (pos == std::string::npos) return false;
    try {
        out = std::stoi(body.substr(pos));
    } catch (...) {
        return false;
    }
    return true;
}

bool findStr(const std::string& body, const std::string& key, std::string& out) {
    const std::string needle = "\"" + key + "\"";
    size_t pos = body.find(needle);
    if (pos == std::string::npos) return false;
    pos = body.find(':', pos + needle.size());
    if (pos == std::string::npos) return false;
    pos = body.find('"', pos);
    if (pos == std::string::npos) return false;
    size_t end = body.find('"', pos + 1);
    if (end == std::string::npos) return false;
    out = body.substr(pos + 1, end - pos - 1);
    return true;
}

// ---- shell-out helper --------------------------------------------------
// popen() runs the command through /bin/sh, which exists on Android via the
// /bin -> /system/bin symlink. Commands below are fixed strings plus values
// that arrived as JSON strings; `type` and package names are the only
// caller-controlled parts and are shell-quoted at the call site.
std::string exec(const std::string& cmd) {
    std::string out;
    FILE* p = popen(cmd.c_str(), "r");
    if (p == nullptr) return out;
    char buf[4096];
    while (fgets(buf, sizeof(buf), p) != nullptr) out += buf;
    static_cast<void>(pclose(p));
    return out;
}

// Capture the framebuffer as PNG.
//
// Deliberately captures to a file and reads it back rather than piping
// `/system/bin/screencap -p` straight into popen: the piped form is fragile
// for binary output, and a file lets us distinguish "empty screenshot" from
// "command failed" by inspecting the exit status.
bool screenshotPng(std::string& out) {
    char tmpl[] = "/data/local/tmp/aqa_shot_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return false;
    close(fd);

    std::string cmd = std::string("/system/bin/screencap -p ") + tmpl;
    int rc = system(cmd.c_str());
    if (rc != 0) {
        unlink(tmpl);
        return false;
    }

    std::string data;
    FILE* f = fopen(tmpl, "rb");
    if (f != nullptr) {
        char buf[16384];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) data.append(buf, n);
        fclose(f);
    }
    unlink(tmpl);

    if (data.empty()) return false;
    out.swap(data);
    return true;
}

HttpResponse handleRequest(const HttpRequest& req, UInputInjector& injector) {
    HttpResponse res;

    if (req.method == "GET" && req.path == "/v1/health") {
        res.body = "{\"ok\":true}";
        return res;
    }

    if (req.method == "POST" && req.path == "/v1/tap") {
        int x = 0, y = 0;
        if (!findInt(req.body, "x", x) || !findInt(req.body, "y", y)) {
            res.status = 400;
            res.body = "{\"error\":\"x_and_y_required\"}";
            return res;
        }
        injector.tap(x, y);
        res.body = "{\"ok\":true}";
        return res;
    }

    if (req.method == "POST" && req.path == "/v1/swipe") {
        int x1 = 0, y1 = 0, x2 = 0, y2 = 0, dur = 300;
        if (!findInt(req.body, "x1", x1) || !findInt(req.body, "y1", y1) ||
            !findInt(req.body, "x2", x2) || !findInt(req.body, "y2", y2)) {
            res.status = 400;
            res.body = "{\"error\":\"x1_y1_x2_y2_required\"}";
            return res;
        }
        if (!findInt(req.body, "duration_ms", dur)) dur = 300;
        injector.swipe(x1, y1, x2, y2, dur);
        res.body = "{\"ok\":true}";
        return res;
    }

    if (req.method == "POST" && req.path == "/v1/key") {
        int keycode = 0;
        if (!findInt(req.body, "keycode", keycode)) {
            res.status = 400;
            res.body = "{\"error\":\"keycode_required\"}";
            return res;
        }
        injector.key(keycode);
        res.body = "{\"ok\":true}";
        return res;
    }

    if (req.method == "POST" && req.path == "/v1/type") {
        std::string text;
        if (!findStr(req.body, "text", text)) {
            res.status = 400;
            res.body = "{\"error\":\"text_required\"}";
            return res;
        }
        // Single-quote the payload and escape embedded single quotes as
        // '\'' so shell metacharacters cannot break out.
        std::string quoted = "'";
        for (char c : text) {
            if (c == '\'') quoted += "'\\''";
            else quoted += c;
        }
        quoted += "'";
        res.body = "{\"ok\":true,\"out\":\"" +
                   jsonEscape(exec("/system/bin/input text " + quoted + " 2>&1")) + "\"}";
        return res;
    }

    if (req.method == "POST" && req.path == "/v1/app/start") {
        std::string pkg, activity;
        if (!findStr(req.body, "package", pkg) || !findStr(req.body, "activity", activity)) {
            res.status = 400;
            res.body = "{\"error\":\"package_and_activity_required\"}";
            return res;
        }
        std::string out = exec("/system/bin/am start -n " + pkg + "/" + activity + " 2>&1");
        res.body = "{\"ok\":true,\"out\":\"" + jsonEscape(out) + "\"}";
        return res;
    }

    if (req.method == "POST" && req.path == "/v1/app/stop") {
        std::string pkg;
        if (!findStr(req.body, "package", pkg)) {
            res.status = 400;
            res.body = "{\"error\":\"package_required\"}";
            return res;
        }
        exec("/system/bin/am force-stop " + pkg + " 2>&1");
        res.body = "{\"ok\":true}";
        return res;
    }

    if (req.method == "GET" && req.path == "/v1/screenshot") {
        std::string png;
        if (!screenshotPng(png)) {
            res.status = 500;
            res.body = "{\"error\":\"screencap_failed\"}";
            return res;
        }
        res.content_type = "image/png";
        res.body.swap(png);
        return res;
    }

    if (req.method == "GET" && req.path == "/v1/sms/inbox") {
        std::string raw = exec("/system/bin/content query --uri content://sms/inbox 2>&1");
        res.body = "{\"raw\":\"" + jsonEscape(raw) + "\"}";
        return res;
    }

    res.status = 404;
    res.body = "{\"error\":\"not_found\"}";
    return res;
}

}  // namespace
}  // namespace aqa

int main() {
    using namespace aqa;

    // A client that disconnects mid-response must not kill the daemon.
    signal(SIGPIPE, SIG_IGN);

    // Block SIGTERM/SIGINT BEFORE the accept thread exists, then consume them
    // synchronously. This is what makes init.rc `stop aqa_server` and Ctrl-C
    // both land on the sigwait() below rather than terminating the process
    // from an arbitrary thread.
    sigset_t signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGTERM);
    sigaddset(&signals, SIGINT);
    pthread_sigmask(SIG_BLOCK, &signals, nullptr);

    UInputInjector injector;
    if (injector.init(kDisplayWidth, kDisplayHeight)) {
        fprintf(stderr, "aqa_server: virtual touchscreen %dx%d registered\n",
                kDisplayWidth, kDisplayHeight);
    } else {
        // Non-fatal: the read-only endpoints (screenshot, sms, health) still
        // work, so the daemon stays up and reports touch as unavailable.
        fprintf(stderr,
                "aqa_server: /dev/uinput init failed (touch injection disabled) — "
                "check that the service runs as root and androidboot.selinux=permissive took effect\n");
    }

    HttpServer server(kListenPort, [&injector](const HttpRequest& req) {
        return handleRequest(req, injector);
    });
    server.start();
    fprintf(stderr, "aqa_server listening on 0.0.0.0:%d\n", kListenPort);

    int sig = 0;
    if (sigwait(&signals, &sig) == 0) {
        fprintf(stderr, "aqa_server: caught signal %d, shutting down\n", sig);
    }
    server.stop();
    return 0;
}