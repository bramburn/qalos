// vendor/aqa/server/src/http_server.hpp
//
// Minimal HTTP/1.1 server. Deliberately dependency-free — the daemon lives
// inside an AOSP build where adding new third-party deps is a non-starter.
// It implements only what the aqa_server API needs:
//
//   - single-threaded accept loop on a configurable port
//   - flat JSON request parsing (hand-rolled scanner in main.cpp)
//   - JSON response encoding
//   - binary passthrough for /v1/screenshot (Content-Type: image/png)
//
// It is NOT a general-purpose server: no TLS, no keep-alive, no auth, no
// chunked encoding. Bind it only to a private network.

#ifndef AQA_HTTP_SERVER_HPP
#define AQA_HTTP_SERVER_HPP

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <thread>

namespace aqa {

struct HttpRequest {
    std::string method;
    std::string path;  // query string is stripped
    std::map<std::string, std::string> headers;
    std::string body;
};

struct HttpResponse {
    int status = 200;
    std::string content_type = "application/json";
    std::string body;
};

using HttpHandler = std::function<HttpResponse(const HttpRequest&)>;

class HttpServer {
public:
    HttpServer(int port, HttpHandler handler);
    ~HttpServer();

    // Starts the accept thread. If the socket cannot be bound or listened on,
    // the server stays stopped (no thread is created) — callers should treat
    // a missing "listening" log line as a bind failure.
    void start();

    // Idempotent. Safe to call from the destructor and explicitly.
    void stop();

private:
    int port_;
    HttpHandler handler_;
    std::atomic<bool> running_{false};
    std::thread accept_thread_;
    int listen_fd_ = -1;

    void acceptLoop();
};

}  // namespace aqa

#endif  // AQA_HTTP_SERVER_HPP