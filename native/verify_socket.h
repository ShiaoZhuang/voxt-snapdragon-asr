#pragma once

// Winsock includes Windows headers in the llama-context.cpp translation unit.
// Keep the SDK's min/max macros out of llama.cpp's std::min/std::max calls.
#if defined(_WIN32) && !defined(NOMINMAX)
#define NOMINMAX
#endif

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <vector>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

namespace voxt_live {
// One framed request/response per connection. The worker binds loopback and
// publishes its random port and per-run token before any model request.
class verify_socket {
#ifdef _WIN32
    SOCKET fd = INVALID_SOCKET;
    static int net_error() { return WSAGetLastError(); }
#else
    int fd = -1;
    static int net_error() { return errno; }
#endif
    static void check(bool ok, const char * op) {
        if (!ok) {
            const int code = net_error();
            throw std::runtime_error(std::string("QNN loopback ") + op + " failed, OS error " + std::to_string(code));
        }
    }
public:
    verify_socket(const verify_socket &) = delete;
    verify_socket & operator=(const verify_socket &) = delete;
    verify_socket() {
#ifdef _WIN32
        WSADATA data;
        const int err = WSAStartup(MAKEWORD(2,2), &data);
        if (err) { throw std::runtime_error("QNN WSAStartup failed: " + std::to_string(err)); }
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd == INVALID_SOCKET) {
            const int code = net_error();
            WSACleanup();
            throw std::runtime_error("QNN socket creation failed: " + std::to_string(code));
        }
#else
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        check(fd >= 0, "socket");
#endif
    }
    ~verify_socket() {
#ifdef _WIN32
        closesocket(fd);
        WSACleanup();
#else
        close(fd);
#endif
    }
    void connect_worker() {
        const char * value = std::getenv("VOXT_QNN_VERIFY_PORT");
        char * end = nullptr;
        const long port = value ? std::strtol(value, &end, 10) : 0;
        if (!port || port < 0 || port > 65535 || !end || *end) { throw std::runtime_error("Invalid QNN worker port"); }
#ifdef _WIN32
        const DWORD timeout = 30000;
#else
        const timeval timeout{30,0};
#ifdef SO_NOSIGPIPE
        const int on = 1;
        check(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on)) == 0, "SIGPIPE option");
#endif
#endif
        for (int option : {SO_SNDTIMEO, SO_RCVTIMEO}) {
            check(setsockopt(fd, SOL_SOCKET, option, reinterpret_cast<const char *>(&timeout), sizeof(timeout)) == 0, "timeout option");
        }
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(static_cast<uint16_t>(port));
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        check(::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0, "connect");
    }
    void send_all(const void * data, size_t size) {
        auto p = static_cast<const char *>(data);
        while (size) {
#ifdef MSG_NOSIGNAL
            constexpr int flags = MSG_NOSIGNAL;
#else
            constexpr int flags = 0;
#endif
            auto n = send(fd, p, static_cast<int>(std::min<size_t>(size, 1 << 20)), flags);
            check(n > 0, "send");
            size -= n;
            p += n;
        }
    }
    void receive(void * data, size_t size) {
        auto p = static_cast<char *>(data);
        while (size) {
            auto n = recv(fd, p, static_cast<int>(std::min<size_t>(size, 1 << 20)), 0);
            if (n == 0) { throw std::runtime_error("QNN worker closed connection before the complete reply"); }
            check(n > 0, "receive");
            p += n;
            size -= n;
        }
    }
};
}
