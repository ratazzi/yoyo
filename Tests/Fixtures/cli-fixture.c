#include <dlfcn.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>

static int startup_ok;
static long startup_offset;

__attribute__((constructor)) static void first_timezone_read(void) {
    int (*ready)(void) = dlsym(RTLD_DEFAULT, "timezone_hooks_ready");
    time_t epoch = 0;
    struct tm result;
    int converted = localtime_r(&epoch, &result) != NULL;
    int injected = ready && ready();
    startup_offset = converted ? result.tm_gmtoff : 0L;
    startup_ok = injected && converted;
    printf("first constructor: injected=%s offset=%ld %s\n",
           injected ? "yes" : "no", converted ? result.tm_gmtoff : 0L,
           startup_ok ? "PASS" : "FAIL");
}

int main(int argc, char **argv) {
    long expected = 9 * 3600;
    if (argc > 1) {
        char *end;
        expected = strtol(argv[1], &end, 10);
        if (!argv[1][0] || *end) return 2;
    }
    int valid = startup_ok && startup_offset == expected;
    printf("startup offset expected=%ld actual=%ld %s\n", expected, startup_offset, valid ? "PASS" : "FAIL");
    return valid ? 0 : 1;
}
