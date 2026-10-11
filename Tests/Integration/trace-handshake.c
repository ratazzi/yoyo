#include "runtime-trace.h"
#include <assert.h>
#include <errno.h>
#include <mach/message.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long long milliseconds(void) {
    struct timespec now; assert(!clock_gettime(CLOCK_MONOTONIC, &now));
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void interrupted(int number) { (void)number; }

static void check(const char *scenario) {
    char directory[] = "/private/tmp/timezone-trace-XXXXXX";
    assert(mkdtemp(directory));
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    int length = snprintf(address.sun_path, sizeof(address.sun_path), "%s/control.sock", directory);
    assert(length > 0 && (size_t)length < sizeof(address.sun_path));
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(server >= 0 && !bind(server, (struct sockaddr *)&address, sizeof(address)) && !listen(server, 8));
    int unavailable = !strcmp(scenario, "unavailable");
    int timeout = !strcmp(scenario, "timeout");
    if (unavailable) { close(server); server = -1; }
    assert(!setenv("TIMEZONE_LAB_LOG_SOCKET", address.sun_path, 1));
    assert(!setenv("TIMEZONE_LAB_SESSION", "handshake-test", 1));
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        if (server >= 0) close(server);
        signal(SIGUSR1, interrupted);
        timezone_trace_configure();
        long long start = milliseconds();
        errno = EDOM;
        int confirmed = timezone_trace_startup("Asia/Tokyo");
        int valid = errno == EDOM && confirmed == !(unavailable || timeout) && milliseconds() - start < 700;
        _exit(valid ? 0 : 1);
    }
    if (!strcmp(scenario, "delayed-accept")) usleep(80000);
    char first_receipt[33] = {0}; int requests = 0;
    long long deadline = milliseconds() + 900;
    while (server >= 0 && milliseconds() < deadline) {
        struct pollfd pending = {.fd = server, .events = POLLIN};
        if (poll(&pending, 1, 100) <= 0) {
            if (timeout) continue;
            break;
        }
        int client = accept(server, NULL, NULL); assert(client >= 0);
        // Capture at accept, before simulating slow request handling.
        audit_token_t audit; socklen_t size = sizeof(audit);
        int authenticated = !getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, &audit, &size);
        char message[512]; ssize_t count = read(client, message, sizeof(message) - 1);
        if (!authenticated || size != sizeof(audit) || (pid_t)audit.val[5] != child || count <= 0) { close(client); continue; }
        message[count] = 0;
        assert(strstr(message, "hooks_loaded"));
        char *receipt = strstr(message, "\"receipt\":\""); assert(receipt);
        receipt += strlen("\"receipt\":\""); assert(strlen(receipt) >= 33 && receipt[32] == '"');
        receipt[32] = 0;
        if (!requests) strcpy(first_receipt, receipt);
        else assert(!strcmp(first_receipt, receipt));
        requests++;
        int no_signal = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &no_signal, sizeof(no_signal));
        if (timeout) { usleep(100000); close(client); continue; }
        if (requests == 1 && (!strcmp(scenario, "lost-reply") || !strcmp(scenario, "slow-handler"))) {
            if (!strcmp(scenario, "slow-handler")) usleep(160000);
            close(client); continue;
        }
        if (requests == 1 && !strcmp(scenario, "rejected-reply")) {
            const char error[] = "{\"error\":\"not accepted\"}\n";
            assert(send(client, error, sizeof(error) - 1, 0) == sizeof(error) - 1);
            close(client); continue;
        }
        if (requests == 1 && !strcmp(scenario, "wrong-receipt")) {
            const char wrong[] = "{\"ack\":\"00000000000000000000000000000000\"}\n";
            assert(send(client, wrong, sizeof(wrong) - 1, 0) == sizeof(wrong) - 1);
            close(client); continue;
        }
        char reply[64]; length = snprintf(reply, sizeof(reply), "{\"ack\":\"%s\"}\n", receipt);
        if (requests == 1 && !strcmp(scenario, "embedded-nul")) {
            reply[length - 1] = 0; reply[length] = 'x'; reply[length + 1] = '\n';
            assert(send(client, reply, (size_t)length + 2, 0) == length + 2);
            close(client); continue;
        }
        if (!strcmp(scenario, "interrupted-reply")) { assert(!kill(child, SIGUSR1)); usleep(20000); }
        if (!strcmp(scenario, "fragmented-reply")) {
            assert(send(client, reply, 7, 0) == 7); usleep(20000);
            assert(send(client, reply + 7, (size_t)length - 7, 0) == length - 7);
        } else assert(send(client, reply, (size_t)length, 0) == length);
        close(client); break;
    }
    if (server >= 0) close(server);
    int status; assert(waitpid(child, &status, 0) == child);
    int retry = !strcmp(scenario, "lost-reply") || !strcmp(scenario, "slow-handler") ||
        !strcmp(scenario, "rejected-reply") || !strcmp(scenario, "wrong-receipt") || !strcmp(scenario, "embedded-nul");
    int valid = WIFEXITED(status) && WEXITSTATUS(status) == 0 && (!retry || requests >= 2);
    assert(!unlink(address.sun_path) && !rmdir(directory));
    printf("Startup receipt %s: %s (requests=%d)\n", scenario, valid ? "PASS" : "FAIL", requests);
    assert(valid);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    const char *cases[] = {"delayed-accept", "lost-reply", "slow-handler", "rejected-reply", "wrong-receipt", "fragmented-reply", "embedded-nul", "interrupted-reply", "unavailable", "timeout"};
    for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); i++) check(cases[i]);
    return 0;
}
