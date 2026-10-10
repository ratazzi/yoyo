#include <stdio.h>
#include <stdlib.h>
#include <time.h>

__attribute__((constructor)) static void configure_timezone(void) {
    const char *zone = getenv("PROCESS_TIMEZONE");
    fprintf(stderr, "[timezone probe] dylib constructor executed\n");
    if (zone) {
        setenv("TZ", zone, 1);
        tzset();
    }
}
