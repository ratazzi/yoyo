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
void timezone_trace_call(const char *operation, const char *zone) {
    if (!socket_path[0] || writing_trace) return;
    if (strcmp(operation, "hooks_loaded") && (!enabled_flag || !atomic_load_explicit(enabled_flag, memory_order_relaxed))) return;
    writing_trace = 1;
    int saved = errno;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd >= 0) {
        fcntl(fd, F_SETFL, O_NONBLOCK);
        int no_signal = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_signal, sizeof(no_signal));
        struct sockaddr_un address = {.sun_family = AF_UNIX};
        strlcpy(address.sun_path, socket_path, sizeof(address.sun_path));
        int connected = connect(fd, (struct sockaddr *)&address, sizeof(address));
        if (connected == 0 || errno == EINPROGRESS) {
            struct pollfd pending = {.fd = fd, .events = POLLOUT};
            if (connected == 0 || poll(&pending, 1, 5) > 0) {
                // All values are controlled ASCII identifiers: no args, env or file data.
                char line[512];
                int length = snprintf(line, sizeof(line), "{\"command\":\"trace\",\"session\":\"%s\",\"operation\":\"%s\",\"zone\":\"%s\"}\n", session, operation, zone ?: configured_zone);
                if (length > 0 && length < (int)sizeof(line) && send(fd, line, (size_t)length, MSG_DONTWAIT) == length) {
                    // Keep the peer alive until the daemon has authenticated and
                    // consumed the message. Short-lived CLI processes can otherwise
                    // exit before LOCAL_PEERPID and session validation complete.
                    struct pollfd reply = {.fd = fd, .events = POLLIN};
                    if (poll(&reply, 1, 20) > 0) { char ignored[128]; recv(fd, ignored, sizeof(ignored), MSG_DONTWAIT); }
                }
            }
        }
        close(fd);
    }
    errno = saved;
    writing_trace = 0;
}
