// vendor/aqa/server/src/main.cpp
//
// aqa_server entry point. Listens on 0.0.0.0:8080 and exposes the REST
// endpoints documented in vendor/aqa/server/README.md.
//
// This is the VENDOR/QA-TESTBED control plane. It deliberately mirrors the
// access-control contract of the framework-level RemoteControlService
// (packages/apps/RemoteControlService, port 9000): same bearer-token file,
// same "loopback is trusted / off-box requires Bearer" rule, same
// {code,message,field} error envelope. Two control planes that disagree about
// auth and error shape are a defect, not a feature.
//
// Signal handling: SIGTERM/SIGINT are BLOCKED in the main thread BEFORE the
// HttpServer accept thread is created, then consumed with sigwait(). Blocking
// first is what makes sigwait reliable. SIGPIPE is ignored so a client
// disconnecting mid-response produces an EPIPE return rather than killing the
// daemon.

#include "http_server.hpp"
#include "uinput_injector.hpp"

// android/log.h only exists in a bionic build. The host smoke-test path in
// README.md compiles this file with plain g++, so provide the two macros it
// uses rather than making host builds conditional on the whole file.
#ifdef __ANDROID__
#include <android/log.h>
#else
#include <cstdarg>
#define ANDROID_LOG_INFO 4
#define ANDROID_LOG_WARN 5
static inline int __android_log_print(int, const char* tag, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[%s] ", tag);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    return 0;
}
#endif

#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>
#include <sys/stat.h>

namespace aqa {
namespace {

constexpr int kDisplayWidth = 1440;   // Pixel 7 Pro QHD+
constexpr int kDisplayHeight = 3120;
constexpr int kListenPort = 8080;

// Shared with RemoteControlService — whichever service starts first creates
// it, and both read the same value. Keep this path in sync with
// RemoteControlService.TOKEN_PATH.
constexpr const char* kTokenPath = "/data/local/tmp/qalos_token";

constexpr const char* kLogTag = "aqa_server";
constexpr const char* kAuditTag = "aqa_audit";

// ---- logging -----------------------------------------------------------
// Every state-changing request is logged to logcat under aqa_audit. legal/
// AGENTS.md 2.9 requires an audit trail for any device running a prebuilt
// image in a commercial context; logcat is the on-device substrate that
// RemoteControlService's event capture also feeds.
void audit(const char* method, const std::string& path,
           const std::string& client, const std::string& detail) {
    __android_log_print(ANDROID_LOG_INFO, kAuditTag, "%s %s client=%s %s",
                        method, path.c_str(),
                        client.empty() ? "unknown" : client.c_str(),
                        detail.c_str());
}

void warn(const char* msg) {
    __android_log_print(ANDROID_LOG_WARN, kLogTag, "%s", msg);
}

// ---- tiny JSON helpers -------------------------------------------------
// Request bodies are trusted in shape (flat objects, QA daemon on a private
// network), so this is a scanner rather than a parser. Keys are matched WITH
// their surrounding quotes, which is what stops a lookup for "x" from
// matching "x1" in a swipe payload.
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

// ---- response helpers --------------------------------------------------
// Error envelope matches RemoteControlService exactly so a client can use one
// error-handling path against either port.
HttpResponse err(int status, const std::string& code,
                 const std::string& message, const std::string& field = "") {
    HttpResponse res;
    res.status = status;
    std::string body = "{\"code\":\"" + jsonEscape(code) +
                       "\",\"message\":\"" + jsonEscape(message) + "\"";
    if (!field.empty()) body += ",\"field\":\"" + jsonEscape(field) + "\"";
    body += "}";
    res.body = body;
    return res;
}

HttpResponse ok(const std::string& body) {
    HttpResponse res;
    res.body = body.empty() ? "{\"ok\":true}" : body;
    return res;
}

// ---- shell / file helpers ----------------------------------------------
std::string exec(const std::string& cmd) {
    std::string out;
    FILE* p = popen(cmd.c_str(), "r");
    if (p == nullptr) return out;
    char buf[4096];
    while (fgets(buf, sizeof(buf), p) != nullptr) out += buf;
    static_cast<void>(pclose(p));
    return out;
}

int execStatus(const std::string& cmd) {
    int rc = system(cmd.c_str());
    if (rc == -1) return -1;
    return rc;
}

bool readFile(const std::string& path, std::string& out) {
    FILE* f = fopen(path.c_str(), "rb");
    if (f == nullptr) return false;
    char buf[16384];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.append(buf, n);
    fclose(f);
    return !out.empty();
}

// POSIX single-quote escaping for values interpolated into a shell command.
std::string shellQuote(const std::string& in) {
    std::string q = "'";
    for (char c : in) {
        if (c == '\'') q += "'\\''";
        else q += c;
    }
    q += "'";
    return q;
}

// ---- screenshot --------------------------------------------------------
// Capture to a file and read it back. Piping `screencap -p` through a stream
// is fragile for binary output and makes failure indistinguishable from an
// empty framebuffer; a file lets us check the exit status.
//
// NOTE: unlike RemoteControlService, ?width/?height scaling is NOT
// implemented — that would need a PNG resizer, and this daemon takes no
// third-party deps. The full-resolution image is returned.
bool screenshotPng(std::string& out) {
    char tmpl[] = "/data/local/tmp/aqa_shot_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return false;
    close(fd);

    if (execStatus(std::string("/system/bin/screencap -p ") + tmpl) != 0) {
        unlink(tmpl);
        return false;
    }
    bool got = readFile(tmpl, out);
    unlink(tmpl);
    return got;
}

// ---- foreground component ----------------------------------------------
// Best-effort: the dumpsys shape differs between releases, so try the
// activity dump first and fall back to the window dump. Returns the raw
// matched line plus the component string when one can be extracted.
void foreground(std::string& component, std::string& raw) {
    raw = exec("/system/bin/dumpsys activity activities 2>/dev/null "
               "| /system/bin/grep -m1 -E 'ResumedActivity'");
    if (raw.empty()) {
        raw = exec("/system/bin/dumpsys window 2>/dev/null "
                   "| /system/bin/grep -m1 -E 'mCurrentFocus'");
    }

    size_t u0 = raw.find(" u0 ");
    if (u0 == std::string::npos) return;
    size_t start = u0 + 4;
    size_t end = raw.find_first_of(" }", start);
    if (end == std::string::npos) end = raw.size();
    component = raw.substr(start, end - start);
}

// ---- SMS inbox ---------------------------------------------------------
// Slice a `content query` row into its fields.
//
// `content query` emits `Row: N key=value, key=value, ...` with NO quoting, so
// splitting on ", " is wrong — SMS bodies routinely contain commas. Instead we
// locate each requested projection key and slice up to the next key marker.
// That is correct as long as no field VALUE contains a literal later marker
// (e.g. a body containing the text ", date="), which is documented as the
// limit of this approach. ?raw=1 returns the unparsed output for debugging.
bool sliceField(const std::string& row,
                const std::vector<std::pair<std::string, size_t>>& markers,
                size_t index, std::string& out) {
    size_t valueStart = markers[index].second + markers[index].first.size();
    size_t valueEnd = (index + 1 < markers.size()) ? markers[index + 1].second : row.size();
    if (valueEnd < valueStart) return false;
    std::string value = row.substr(valueStart, valueEnd - valueStart);
    while (!value.empty() && (value.back() == ' ' || value.back() == ',')) value.pop_back();
    out = value;
    return true;
}

std::string smsInboxJson() {
    const std::string keys[3] = {"address=", "body=", "date="};
    std::string out =
        exec("/system/bin/content query --uri content://sms/inbox "
             "--projection address:body:date --user 0 2>&1");

    std::string json = "{\"messages\":[";
    bool first = true;

    size_t lineStart = 0;
    while (lineStart < out.size()) {
        size_t lineEnd = out.find('\n', lineStart);
        if (lineEnd == std::string::npos) lineEnd = out.size();
        std::string line = out.substr(lineStart, lineEnd - lineStart);
        lineStart = lineEnd + 1;

        if (line.compare(0, 5, "Row: ") != 0) continue;

        std::vector<std::pair<std::string, size_t>> markers;
        for (const std::string& k : keys) {
            size_t p = line.find(k);
            if (p != std::string::npos) markers.emplace_back(k, p);
        }
        if (markers.size() < 3) continue;

        // Markers may be found out of projection order; sort by position so
        // "next marker" is well defined.
        for (size_t i = 0; i + 1 < markers.size(); ++i) {
            for (size_t j = i + 1; j < markers.size(); ++j) {
                if (markers[j].second < markers[i].second) {
                    std::swap(markers[i], markers[j]);
                }
            }
        }

        std::string address, body, date;
        sliceField(line, markers, 0, address);
        sliceField(line, markers, 1, body);
        sliceField(line, markers, 2, date);

        if (!first) json += ",";
        first = false;
        json += "{\"address\":\"" + jsonEscape(address) +
                "\",\"body\":\"" + jsonEscape(body) +
                "\",\"date\":\"" + jsonEscape(date) + "\"}";
    }

    json += "]}";
    return json;
}

// ---- auth --------------------------------------------------------------
std::string readTokenFile() {
    std::string token;
    if (!readFile(kTokenPath, token)) return "";
    while (!token.empty() &&
           (token.back() == '\n' || token.back() == '\r' || token.back() == ' ')) {
        token.pop_back();
    }
    return token;
}

// Same rule as RemoteControlService: loopback is trusted (same-device access
// via adb), everything else must present the shared bearer token. A missing
// token file means every off-box request is rejected — the safe failure mode,
// not an open door.
bool authorized(const HttpRequest& req, const std::string& token) {
    if (req.client_is_loopback) return true;
    if (token.empty()) return false;

    auto it = req.headers.find("Authorization");
    if (it == req.headers.end()) return false;

    const std::string prefix = "Bearer ";
    if (it->second.compare(0, prefix.size(), prefix) != 0) return false;
    const std::string presented = it->second.substr(prefix.size());

    // Constant-time compare: no early exit on the first mismatching byte.
    if (presented.size() != token.size()) return false;
    unsigned char diff = 0;
    for (size_t i = 0; i < token.size(); ++i) {
        diff |= static_cast<unsigned char>(presented[i] ^ token[i]);
    }
    return diff == 0;
}

// ---- routing -----------------------------------------------------------
HttpResponse dispatch(const HttpRequest& req, UInputInjector& injector) {
    // /v1/health stays unauthenticated: it is a liveness probe, and it leaks
    // nothing beyond the fact that the port is open.
    if (req.method == "GET" && req.path == "/v1/health") {
        return ok("{\"ok\":true,\"port\":8080}");
    }

    if (req.method == "GET" && req.path == "/v1/display") {
        return ok("{\"width\":" + std::to_string(kDisplayWidth) +
                  ",\"height\":" + std::to_string(kDisplayHeight) + "}");
    }

    if (req.method == "POST" && req.path == "/v1/tap") {
        int x = 0, y = 0;
        if (!findInt(req.body, "x", x)) {
            return err(400, "MISSING_FIELD", "x is required", "x");
        }
        if (!findInt(req.body, "y", y)) {
            return err(400, "MISSING_FIELD", "y is required", "y");
        }
        injector.tap(x, y);
        audit("POST", req.path, req.client_addr,
              "x=" + std::to_string(x) + " y=" + std::to_string(y));
        return ok("");
    }

    if (req.method == "POST" && req.path == "/v1/swipe") {
        int x1 = 0, y1 = 0, x2 = 0, y2 = 0, dur = 300;
        if (!findInt(req.body, "x1", x1)) return err(400, "MISSING_FIELD", "x1 is required", "x1");
        if (!findInt(req.body, "y1", y1)) return err(400, "MISSING_FIELD", "y1 is required", "y1");
        if (!findInt(req.body, "x2", x2)) return err(400, "MISSING_FIELD", "x2 is required", "x2");
        if (!findInt(req.body, "y2", y2)) return err(400, "MISSING_FIELD", "y2 is required", "y2");
        if (!findInt(req.body, "duration_ms", dur)) dur = 300;
        injector.swipe(x1, y1, x2, y2, dur);
        audit("POST", req.path, req.client_addr,
              "x1=" + std::to_string(x1) + " y1=" + std::to_string(y1) +
              " x2=" + std::to_string(x2) + " y2=" + std::to_string(y2) +
              " duration_ms=" + std::to_string(dur));
        return ok("");
    }

    if (req.method == "POST" && req.path == "/v1/key") {
        int keycode = 0;
        if (!findInt(req.body, "keycode", keycode)) {
            return err(400, "MISSING_FIELD", "keycode is required", "keycode");
        }
        injector.key(keycode);
        audit("POST", req.path, req.client_addr, "keycode=" + std::to_string(keycode));
        return ok("");
    }

    if (req.method == "POST" && req.path == "/v1/type") {
        std::string text;
        if (!findStr(req.body, "text", text)) {
            return err(400, "MISSING_FIELD", "text is required", "text");
        }
        // The one input path that does NOT go through /dev/uinput: `input
        // text` handles arbitrary Unicode, which per-keycode injection cannot.
        // Kept as a shell-out deliberately, and documented as such.
        std::string out = exec("/system/bin/input text " + shellQuote(text) + " 2>&1");
        audit("POST", req.path, req.client_addr,
              "chars=" + std::to_string(text.size()));
        return ok("{\"ok\":true,\"out\":\"" + jsonEscape(out) + "\"}");
    }

    if (req.method == "POST" && req.path == "/v1/app/start") {
        std::string pkg, activity;
        if (!findStr(req.body, "package", pkg)) {
            return err(400, "MISSING_FIELD", "package is required", "package");
        }
        if (!findStr(req.body, "activity", activity)) {
            return err(400, "MISSING_FIELD", "activity is required", "activity");
        }
        std::string out = exec("/system/bin/am start -n " + pkg + "/" + activity + " 2>&1");
        audit("POST", req.path, req.client_addr, "package=" + pkg + " activity=" + activity);

        // `am` exits 0 even when the component does not exist, so the output
        // text is the only signal. Surface it rather than reporting success.
        if (out.find("Error") != std::string::npos ||
            out.find("Exception") != std::string::npos ||
            out.find("does not exist") != std::string::npos) {
            HttpResponse res = err(400, "LAUNCH_FAILED", "am refused the launch", "package");
            res.body = "{\"code\":\"LAUNCH_FAILED\",\"message\":\"am refused the launch\","
                       "\"field\":\"package\",\"out\":\"" + jsonEscape(out) + "\"}";
            return res;
        }
        return ok("{\"ok\":true,\"out\":\"" + jsonEscape(out) + "\"}");
    }

    if (req.method == "POST" && req.path == "/v1/app/stop") {
        std::string pkg;
        if (!findStr(req.body, "package", pkg)) {
            return err(400, "MISSING_FIELD", "package is required", "package");
        }
        exec("/system/bin/am force-stop " + pkg + " 2>&1");
        audit("POST", req.path, req.client_addr, "package=" + pkg);
        return ok("");
    }

    if (req.method == "GET" && req.path == "/v1/screenshot") {
        std::string png;
        if (!screenshotPng(png)) {
            return err(500, "SCREENCAP_FAILED", "screencap produced no output");
        }
        HttpResponse res;
        res.content_type = "image/png";
        res.body.swap(png);
        return res;
    }

    // uiautomator dump is what makes this API usable for real automation —
    // without it a client can only blind-tap coordinates. Returns the raw
    // XML; the client does the parsing.
    if (req.method == "GET" && req.path == "/v1/ui/dump") {
        const std::string xmlPath = "/data/local/tmp/aqa_ui.xml";
        unlink(xmlPath.c_str());
        exec("/system/bin/uiautomator dump " + xmlPath + " 2>&1");
        std::string xml;
        if (!readFile(xmlPath, xml)) {
            return err(500, "UI_DUMP_FAILED", "uiautomator dump produced no file");
        }
        HttpResponse res;
        res.content_type = "application/xml";
        res.body.swap(xml);
        return res;
    }

    if (req.method == "GET" && req.path == "/v1/foreground") {
        std::string component, raw;
        foreground(component, raw);
        std::string body = "{\"component\":\"" + jsonEscape(component) + "\"";
        if (req.query.find("raw=1") != std::string::npos) {
            body += ",\"raw\":\"" + jsonEscape(raw) + "\"";
        }
        body += "}";
        return ok(body);
    }

    if (req.method == "GET" && req.path == "/v1/sms/inbox") {
        // ?raw=1 returns the unparsed `content query` output, which is the
        // escape hatch when the field-slicing heuristic mis-splits a body.
        if (req.query.find("raw=1") != std::string::npos) {
            std::string out = exec("/system/bin/content query --uri content://sms/inbox "
                                   "--projection address:body:date --user 0 2>&1");
            return ok("{\"raw\":\"" + jsonEscape(out) + "\"}");
        }
        return ok(smsInboxJson());
    }

    return err(404, "NOT_FOUND", "no such endpoint: " + req.path);
}

}  // namespace
}  // namespace aqa

int main() {
    using namespace aqa;

    signal(SIGPIPE, SIG_IGN);

    // Block SIGTERM/SIGINT BEFORE the accept thread exists, then consume them
    // synchronously, so init's `stop` and Ctrl-C both land on sigwait().
    sigset_t signals;
    sigemptyset(&signals);
    sigaddset(&signals, SIGTERM);
    sigaddset(&signals, SIGINT);
    pthread_sigmask(SIG_BLOCK, &signals, nullptr);

    const std::string token = readTokenFile();
    if (token.empty()) {
        warn("no bearer token at /data/local/tmp/qalos_token — "
             "all off-box requests will be rejected (loopback still works)");
    } else {
        __android_log_print(ANDROID_LOG_INFO, kLogTag,
                            "bearer token loaded (%zu chars)", token.size());
    }

    UInputInjector injector;
    if (injector.init(kDisplayWidth, kDisplayHeight)) {
        __android_log_print(ANDROID_LOG_INFO, kLogTag,
                            "virtual touchscreen %dx%d registered",
                            kDisplayWidth, kDisplayHeight);
    } else {
        // Non-fatal: the read-only endpoints still work, so stay up and report
        // touch as unavailable rather than failing the service.
        warn("/dev/uinput init failed — touch injection disabled. Check that the "
             "service runs as root and androidboot.selinux=permissive took effect");
    }

    HttpServer server(kListenPort, [&injector, &token](const HttpRequest& req) {
        if (!authorized(req, token)) {
            audit(req.method.c_str(), req.path, req.client_addr, "auth=rejected");
            return err(401, "UNAUTHORIZED", "Bearer token required", "Authorization");
        }
        return dispatch(req, injector);
    });

    server.start();
    __android_log_print(ANDROID_LOG_INFO, kLogTag,
                        "listening on 0.0.0.0:%d", kListenPort);

    int sig = 0;
    if (sigwait(&signals, &sig) == 0) {
        __android_log_print(ANDROID_LOG_INFO, kLogTag, "caught signal %d, shutting down", sig);
    }
    server.stop();
    return 0;
}