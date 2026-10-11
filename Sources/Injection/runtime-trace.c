#include "runtime-trace.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <stdatomic.h>
#include <time.h>

static char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
static char session[80];
static char configured_zone[128];
static _Thread_local int writing_trace;
static const _Atomic unsigned *enabled_flag;

void timezone_trace_configure(void) {
    const char *path = getenv("TIMEZONE_LAB_LOG_SOCKET"), *identifier = getenv("TIMEZONE_LAB_SESSION");
    if (path && identifier) {
        strlcpy(socket_path, path, sizeof(socket_path));
        strlcpy(session, identifier, sizeof(session));
        const char *zone = getenv("TZ");
        if (zone) strlcpy(configured_zone, zone, sizeof(configured_zone));
        const char *control = getenv("TIMEZONE_LAB_TRACE_CONTROL");
        if (control) {
            int fd = open(control, O_RDONLY);
            if (fd >= 0) {
                void *mapping = mmap(NULL, sizeof(unsigned), PROT_READ, MAP_SHARED, fd, 0);
                if (mapping != MAP_FAILED) enabled_flag = mapping;
                close(fd);
            }
        }
    }
}
static int64_t milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int wait_socket(int fd, short events, int64_t deadline) {
    for (;;) {
        int64_t remaining = deadline - milliseconds();
        if (remaining <= 0) return 0;
        struct pollfd pending = {.fd = fd, .events = events};
        int result = poll(&pending, 1, (int)remaining);
        if (result < 0 && errno == EINTR) continue;
        return result > 0 && (pending.revents & events);
    }
}

static int connect_trace(int64_t deadline) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) { close(fd); return -1; }
    int no_signal = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_signal, sizeof(no_signal))) { close(fd); return -1; }
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strlcpy(address.sun_path, socket_path, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) {
        if (errno != EINPROGRESS || !wait_socket(fd, POLLOUT, deadline)) { close(fd); return -1; }
        int error = 0; socklen_t size = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) || error) { close(fd); return -1; }
    }
    return fd;
}

static int startup_attempt(const char *line, size_t length, const char *ack, int64_t deadline) {
    int fd = connect_trace(deadline);
    if (fd < 0) return 0;
    size_t offset = 0;
    while (offset < length) {
        if (milliseconds() >= deadline) { close(fd); return 0; }
        ssize_t count = send(fd, line + offset, length - offset, MSG_DONTWAIT);
        if (count > 0) { offset += (size_t)count; continue; }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && wait_socket(fd, POLLOUT, deadline)) continue;
        close(fd); return 0;
    }
    char reply[512]; offset = 0;
    int confirmed = 0;
    while (offset < sizeof(reply) - 1 && wait_socket(fd, POLLIN, deadline)) {
        ssize_t count = recv(fd, reply + offset, sizeof(reply) - 1 - offset, MSG_DONTWAIT);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) break;
        offset += (size_t)count; reply[offset] = 0;
        char *newline = memchr(reply, '\n', offset);
        if (newline) {
            // The daemon's receipt-only response has one exact representation.
            // Do not treat an error, partial JSON or arbitrary bytes as success.
            *newline = 0;
            confirmed = !memchr(reply, 0, (size_t)(newline - reply)) && !strcmp(reply, ack);
            break;
        }
    }
    close(fd);
    return confirmed;
}

int timezone_trace_startup(const char *zone) {
    if (!socket_path[0] || writing_trace) return 0;
    writing_trace = 1;
    int saved = errno, confirmed = 0;
    unsigned char random[16]; char receipt[33];
    arc4random_buf(random, sizeof(random));
    const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < sizeof(random); i++) { receipt[i * 2] = hex[random[i] >> 4]; receipt[i * 2 + 1] = hex[random[i] & 15]; }
    receipt[32] = 0;
    char line[512], ack[64];
    int length = snprintf(line, sizeof(line), "{\"command\":\"trace\",\"session\":\"%s\",\"operation\":\"hooks_loaded\",\"zone\":\"%s\",\"receipt\":\"%s\"}\n", session, zone ?: configured_zone, receipt);
    snprintf(ack, sizeof(ack), "{\"ack\":\"%s\"}", receipt);
    int64_t deadline = milliseconds() + 500;
    if (length > 0 && length < (int)sizeof(line)) {
        for (int attempt = 0; attempt < 5 && milliseconds() < deadline; attempt++) {
            int64_t attempt_deadline = milliseconds() + 100;
            if (attempt_deadline > deadline) attempt_deadline = deadline;
            if (startup_attempt(line, (size_t)length, ack, attempt_deadline)) { confirmed = 1; break; }
            // Bound connection-error retries as well as reply waits.
            int64_t remaining = deadline - milliseconds();
            if (remaining > 0 && attempt < 4) poll(NULL, 0, remaining < 10 ? (int)remaining : 10);
        }
    }
    errno = saved;
    writing_trace = 0;
    return confirmed;
}

void timezone_trace_call(const char *operation, const char *zone) {
    if (!strcmp(operation, "hooks_loaded")) { timezone_trace_startup(zone); return; }
    if (!socket_path[0] || writing_trace) return;
    if (!enabled_flag || !atomic_load_explicit(enabled_flag, memory_order_relaxed)) return;
    writing_trace = 1;
    int saved = errno;
    int fd = connect_trace(milliseconds());
    if (fd >= 0) {
        // Best effort: ordinary logs never wait for a daemon acknowledgement.
        char line[512];
        int length = snprintf(line, sizeof(line), "{\"command\":\"trace\",\"session\":\"%s\",\"operation\":\"%s\",\"zone\":\"%s\"}\n", session, operation, zone ?: configured_zone);
        if (length > 0 && length < (int)sizeof(line)) send(fd, line, (size_t)length, MSG_DONTWAIT);
        close(fd);
    }
    errno = saved;
    writing_trace = 0;
}
