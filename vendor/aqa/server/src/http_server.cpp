// vendor/aqa/server/src/http_server.cpp

#include "http_server.hpp"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cstring>
#include <sstream>

namespace aqa {
namespace {

// Reason phrases. Deliberately a small explicit table rather than a
// status-only "OK"/"Internal Server Error" pair — a 404 that answers with
// "Internal Server Error" sends clients down the wrong debugging path.
const char* reasonPhrase(int status) {
    switch (status) {
        case 200: return "OK";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 500: return "Internal Server Error";
        default:  return "Unknown";
    }
}

bool sendAll(int fd, const char* data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, data + sent, len - sent, 0);
        if (n <= 0) return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool readRequest(int fd, HttpRequest& req) {
    std::string buf;
    char chunk[4096];
    size_t header_end = std::string::npos;

    while (true) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) return false;
        buf.append(chunk, static_cast<size_t>(n));

        if (header_end == std::string::npos) {
            size_t pos = buf.find("\r\n\r\n");
            if (pos != std::string::npos) header_end = pos + 4;
        }
        if (header_end == std::string::npos) continue;

        size_t content_length = 0;
        size_t cl = buf.find("Content-Length:");
        if (cl != std::string::npos) {
            size_t eol = buf.find("\r\n", cl);
            if (eol != std::string::npos) {
                std::string value = buf.substr(cl + 15, eol - cl - 15);
                try {
                    content_length = std::stoul(value);
                } catch (...) {
                    content_length = 0;
                }
            }
        }
        if (buf.size() < header_end + content_length) continue;

        std::istringstream iss(buf.substr(0, header_end - 2));
        std::string line;
        bool first = true;
        while (std::getline(iss, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (first) {
                std::istringstream rl(line);
                rl >> req.method >> req.path;
                first = false;
                continue;
            }
            size_t colon = line.find(':');
            if (colon != std::string::npos) {
                std::string k = line.substr(0, colon);
                std::string v = line.substr(colon + 1);
                while (!v.empty() && v.front() == ' ') v.erase(0, 1);
                req.headers[k] = v;
            }
        }

        // Strip the query string so routing matches on path alone
        // (/v1/screenshot?raw=1 still routes), but keep it for handlers that
        // need the parameters.
        size_t q = req.path.find('?');
        if (q != std::string::npos) {
            req.query = req.path.substr(q + 1);
            req.path.erase(q);
        }

        req.body = buf.substr(header_end, content_length);
        return true;
    }
}

void writeResponse(int fd, const HttpResponse& res) {
    std::ostringstream oss;
    oss << "HTTP/1.1 " << res.status << " " << reasonPhrase(res.status) << "\r\n";
    oss << "Content-Type: " << res.content_type << "\r\n";
    oss << "Content-Length: " << res.body.size() << "\r\n";
    oss << "Connection: close\r\n\r\n";
    std::string header = oss.str();
    if (!sendAll(fd, header.data(), header.size())) return;
    if (!res.body.empty()) {
        static_cast<void>(sendAll(fd, res.body.data(), res.body.size()));
    }
}

}  // namespace

HttpServer::HttpServer(int port, HttpHandler handler)
    : port_(port), handler_(std::move(handler)) {}

HttpServer::~HttpServer() { stop(); }

void HttpServer::start() {
    listen_fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd_ < 0) {
        running_ = false;
        return;
    }

    int yes = 1;
    setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(static_cast<uint16_t>(port_));

    if (bind(listen_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        close(listen_fd_);
        listen_fd_ = -1;
        running_ = false;
        return;
    }
    if (listen(listen_fd_, 16) < 0) {
        close(listen_fd_);
        listen_fd_ = -1;
        running_ = false;
        return;
    }

    running_ = true;
    accept_thread_ = std::thread([this] { acceptLoop(); });
}

void HttpServer::stop() {
    running_ = false;
    if (listen_fd_ >= 0) {
        // shutdown() first: wakes a thread blocked in accept() so the join
        // below cannot hang.
        static_cast<void>(shutdown(listen_fd_, SHUT_RDWR));
        close(listen_fd_);
        listen_fd_ = -1;
    }
    if (accept_thread_.joinable()) accept_thread_.join();
}

void HttpServer::acceptLoop() {
    while (running_) {
        sockaddr_in client{};
        socklen_t clen = sizeof(client);
        int cfd = accept(listen_fd_, reinterpret_cast<sockaddr*>(&client), &clen);
        if (cfd < 0) {
            if (!running_) return;
            continue;
        }
        HttpRequest req;
        if (readRequest(cfd, req)) {
            char addr[INET_ADDRSTRLEN] = {0};
            if (inet_ntop(AF_INET, &client.sin_addr, addr, sizeof(addr)) != nullptr) {
                req.client_addr = addr;
            }

            // Loopback detection must be done on the real peer address, not on
            // a header — this is the same rule RemoteControlService applies, so
            // both APIs accept a shared bearer token from off-box and skip auth
            // only for same-device clients.
            const uint32_t peer = ntohl(client.sin_addr.s_addr);
            req.client_is_loopback = ((peer >> 24) == 127);

            HttpResponse res = handler_(req);
            writeResponse(cfd, res);
        }
        close(cfd);
    }
}

}  // namespace aqa