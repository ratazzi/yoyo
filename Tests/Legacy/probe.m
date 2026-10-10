#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <time.h>
#include <stdlib.h>

static void report(const char *phase) {
    time_t epoch = 0;
    struct tm value;
    localtime_r(&epoch, &value);
    char formatted[128];
    strftime(formatted, sizeof(formatted), "%Y-%m-%d %H:%M:%S %Z %z", &value);
    CFTimeZoneRef system = CFTimeZoneCopySystem();
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss z Z";
    printf("%s TZ=%s\nlibc=%s\nCFSystem=%s\nNSTimeZone.local=%s\nNSTimeZone.default=%s\nformatter=%s\n",
           phase, getenv("TZ") ?: "<unset>", formatted,
           [(__bridge NSString *)CFTimeZoneGetName(system) UTF8String],
           NSTimeZone.localTimeZone.name.UTF8String,
           NSTimeZone.defaultTimeZone.name.UTF8String,
           [[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:0]] UTF8String]);
    CFRelease(system);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (getenv("TZ_PROBE_OUTPUT")) {
            if (!freopen(getenv("TZ_PROBE_OUTPUT"), "w", stdout)) return 2;
        }
        report("startup");
        if (argc > 1) {
            setenv("TZ", argv[1], 1);
            tzset();
            report("changed TZ, libc reset only");
            [NSTimeZone resetSystemTimeZone];
            report("Foundation resetSystemTimeZone");
        }
    }
    return 0;
}
