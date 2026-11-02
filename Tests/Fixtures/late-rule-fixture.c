#include <spawn.h>
#include <dlfcn.h>
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static void report(const char *label) {
    time_t epoch = 0;
    struct tm value;
    localtime_r(&epoch, &value);
    int (*ready)(void) = dlsym(RTLD_DEFAULT, "timezone_hooks_ready");
    printf("%s offset=%ld TZ=%s hook=%d\n", label, value.tm_gmtoff, getenv("TZ") ?: "<unset>", ready && ready());
    fflush(stdout);
}

static int spawn(const char *label, const char *path, const char *grandchild) {
    pid_t pid;
    char *arguments[] = {(char *)path, "--child", (char *)label, (char *)grandchild, NULL};
    // A conflicting environment makes this test detect lost daemon sessions;
    // ordinary OS environment inheritance must not make recovery appear to pass.
    char *conflicting[] = {"TZ=Etc/UTC", NULL};
    int error = posix_spawn(&pid, path, NULL, NULL, arguments, conflicting);
    if (error) { fprintf(stderr, "posix_spawn: %s\n", strerror(error)); return 1; }
    int status;
    if (waitpid(pid, &status, 0) < 0) return 1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

int main(int argc, char **argv) {
    alarm(45);
    if (argc >= 3 && !strcmp(argv[1], "--child")) {
        report(argv[2]);
        return argc > 3 ? spawn("outside-grandchild", argv[3], NULL) : 0;
    }
    if (argc != 3) return 2;
    report("parent-before");
    // The driver adds the app rule only after receiving this line.
    if (getchar() == EOF) return 2;
    report("parent-after");
    int result = spawn("outside-direct-child", argv[1], NULL);
    result |= spawn("inside-app-helper", argv[2], argv[1]);
    return result;
}
