#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>

static int failures;

static void check(const char *phase) {
    time_t epoch = 0;
    struct tm value;
    localtime_r(&epoch, &value);
    char result[128];
    strftime(result, sizeof(result), "%F %T %Z %z", &value);
    CFTimeZoneRef system = CFTimeZoneCopySystem();
    CFTimeZoneRef defaultZone = CFTimeZoneCopyDefault();
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
    NSString *date = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:0]];
    BOOL valid = value.tm_gmtoff == 9 * 3600 &&
        [(__bridge NSString *)CFTimeZoneGetName(system) isEqualToString:@"Asia/Tokyo"] &&
        [(__bridge NSString *)CFTimeZoneGetName(defaultZone) isEqualToString:@"Asia/Tokyo"] &&
        [NSTimeZone.systemTimeZone.name isEqualToString:@"Asia/Tokyo"] &&
        [NSTimeZone.localTimeZone.name isEqualToString:@"Asia/Tokyo"] &&
        [NSTimeZone.defaultTimeZone.name isEqualToString:@"Asia/Tokyo"] &&
        [date isEqualToString:@"1970-01-01 09:00:00 +0900"];
    printf("%s: %s libc=%s CF=%s CFDefault=%s NS=%s formatter=%s\n", phase,
           valid ? "PASS" : "FAIL", result,
           [(__bridge NSString *)CFTimeZoneGetName(system) UTF8String],
           [(__bridge NSString *)CFTimeZoneGetName(defaultZone) UTF8String],
           NSTimeZone.systemTimeZone.name.UTF8String, date.UTF8String);
    if (!valid) failures++;
    CFRelease(system);
    CFRelease(defaultZone);
}

int main(void) {
    @autoreleasepool {
        check("startup");
        unsetenv("TZ");
        tzset();
        [NSTimeZone resetSystemTimeZone];
        check("unsetenv + tzset + NS reset");
        setenv("TZ", "America/New_York", 1);
        tzset();
        CFTimeZoneResetSystem();
        check("setenv New_York + tzset + CF reset");
        static char replacement[] = "TZ=UTC";
        putenv(replacement);
        tzset();
        check("putenv UTC + tzset");
        NSTimeZone.defaultTimeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        check("NS set default UTC");
        CFTimeZoneRef utc = CFTimeZoneCreateWithTimeIntervalFromGMT(NULL, 0);
        CFTimeZoneSetDefault(utc);
        CFRelease(utc);
        check("CF set default UTC");
    }
    return failures ? 1 : 0;
}
