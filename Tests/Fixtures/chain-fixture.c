#include <dlfcn.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    int (*ready)(void) = dlsym(RTLD_DEFAULT, "timezone_hooks_ready");
    time_t epoch = 0; struct tm value; localtime_r(&epoch, &value);
    int loaded = ready && ready();
    printf("pid=%d parent=%d exe=%s offset=%ld hook=%d TZ=%s\n", getpid(), getppid(), argv[0], value.tm_gmtoff, loaded, getenv("TZ") ?: "<unset>");
    fflush(stdout);
    FILE *file = fopen("/tmp/timezone-lab-chain-fixture.txt", "w");
    if (file) { fputs("TEST_CONTENT_MUST_NOT_APPEAR_IN_BEHAVIOR_LOG", file); fclose(file); }
    if (value.tm_gmtoff != strtol(argv[1], NULL, 10) || loaded != atoi(argv[2])) return 1;
    if (argc > 3 && !strcmp(argv[3], "--hold")) { sleep(10); return 0; }
    if (argc > 3) {
        int empty = !strcmp(argv[3], "--empty"); int index = empty ? 4 : 3;
        if (argc < index + 3) return 2;
        pid_t child; char *empty_env[] = {NULL};
        int error = posix_spawn(&child, argv[index], NULL, NULL, argv + index, empty ? empty_env : environ);
        if (error) { fprintf(stderr, "spawn error=%d\n", error); return 1; }
        int status; if (waitpid(child, &status, 0) < 0) return 1;
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }
    return 0;
}
