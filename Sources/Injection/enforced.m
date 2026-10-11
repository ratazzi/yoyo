// Feasibility probe, not a complete per-process timezone virtualization layer.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "timezone-files.h"
#include <stdatomic.h>
#include <fcntl.h>
#include "timezone-policy.h"
#include "runtime-trace.h"

static char *forced_name;
static CFTimeZoneRef forced_zone;
static NSTimeZone *forced_ns_zone;
static atomic_int hooks_installed;
static IMP original_url_resolve;
static IMP original_string_resolve;

// Used by CLI acceptance fixtures to distinguish hooks from TZ-only behavior.
__attribute__((visibility("default"))) int timezone_hooks_ready(void) {
    return atomic_load_explicit(&hooks_installed, memory_order_acquire);
}

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *new_fn; const void *old_fn; } \
    pair_##original __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)&replacement, (const void *)&original \
    }

static char *locked_getenv(const char *name) {
    if (forced_name && strcmp(name, "TZ") == 0) return forced_name;
    if (timezone_files_path() && strcmp(name, "TZFILE") == 0) return (char *)timezone_files_path();
    return getenv(name);
}

static int locked_setenv(const char *name, const char *value, int overwrite) {
    if (forced_name && (!strcmp(name, "TZ") || !strcmp(name, "TZFILE"))) return 0;
    return setenv(name, value, overwrite);
}

static int locked_unsetenv(const char *name) {
    if (forced_name && (!strcmp(name, "TZ") || !strcmp(name, "TZFILE"))) return 0;
    return unsetenv(name);
}

static int locked_putenv(char *entry) {
    if (forced_name && (!strncmp(entry, "TZ=", 3) || !strncmp(entry, "TZFILE=", 7))) return 0;
    return putenv(entry);
}

static void locked_tzset(void) {
    if (forced_name) {
        setenv("TZ", forced_name, 1);
        if (timezone_files_path()) setenv("TZFILE", timezone_files_path(), 1);
    }
    tzset();
}

static CFTimeZoneRef locked_system(void) {
    timezone_trace_call("CF.system", forced_name);
    if (forced_zone) return (CFTimeZoneRef)CFRetain(forced_zone);
    return CFTimeZoneCopySystem();
}

static CFTimeZoneRef locked_default(void) {
    timezone_trace_call("CF.default", forced_name);
    if (forced_zone) return (CFTimeZoneRef)CFRetain(forced_zone);
    return CFTimeZoneCopyDefault();
}

static void locked_set_default(CFTimeZoneRef zone) {
    timezone_trace_call("CF.setDefault", forced_name);
    CFTimeZoneSetDefault(forced_zone ?: zone);
}

static NSTimeZone *ns_forced(id self, SEL selector) {
    timezone_trace_call(selector == @selector(systemTimeZone) ? "NS.system" : selector == @selector(localTimeZone) ? "NS.local" : "NS.default", forced_name);
    return forced_ns_zone;
}

static void ns_ignore_default(id self, SEL selector, NSTimeZone *zone) {}

static NSURL *forced_url_resolve(NSURL *self, SEL selector) {
    const char *replacement = self.isFileURL ? timezone_files_replacement(AT_FDCWD, self.path.fileSystemRepresentation) : NULL;
    return replacement ? [NSURL fileURLWithPath:@(replacement)] : ((NSURL *(*)(id, SEL))original_url_resolve)(self, selector);
}
static NSString *forced_string_resolve(NSString *self, SEL selector) {
    const char *replacement = timezone_files_replacement(AT_FDCWD, self.fileSystemRepresentation);
    return replacement ? @(replacement) : ((NSString *(*)(id, SEL))original_string_resolve)(self, selector);
}

// ICU's public C ABI uses UTF-16 names and an int32 error status.
extern int32_t ucal_getDefaultTimeZone(uint16_t *, int32_t, int32_t *);
extern void ucal_setDefaultTimeZone(const uint16_t *, int32_t *);
enum { ICU_ILLEGAL_ARGUMENT = 1, ICU_ALLOCATION_FAILURE = 7, ICU_BUFFER_OVERFLOW = 15, ICU_NOT_TERMINATED = -124 };
static int32_t forced_icu_default(uint16_t *buffer, int32_t capacity, int32_t *status) {
    timezone_trace_call("ICU.default", forced_name);
    if (!forced_zone) return ucal_getDefaultTimeZone(buffer, capacity, status);
    if (!status || *status > 0) return 0;
    if (capacity < 0 || (!buffer && capacity > 0)) { *status = ICU_ILLEGAL_ARGUMENT; return 0; }
    CFStringRef name = CFTimeZoneGetName(forced_zone);
    int32_t length = (int32_t)CFStringGetLength(name);
    int32_t copy = capacity < length ? capacity : length;
    if (copy) CFStringGetCharacters(name, CFRangeMake(0, copy), buffer);
    if (capacity > length) buffer[length] = 0;
    else *status = capacity < length ? ICU_BUFFER_OVERFLOW : ICU_NOT_TERMINATED;
    return length;
}
static void forced_icu_set_default(const uint16_t *zone, int32_t *status) {
    timezone_trace_call("ICU.setDefault", forced_name);
    if (!forced_zone) { ucal_setDefaultTimeZone(zone, status); return; }
    if (!status || *status > 0) return;
    CFStringRef name = CFTimeZoneGetName(forced_zone);
    CFIndex length = CFStringGetLength(name);
    uint16_t *forced = calloc((size_t)length + 1, sizeof(uint16_t));
    if (!forced) { *status = ICU_ALLOCATION_FAILURE; return; }
    CFStringGetCharacters(name, CFRangeMake(0, length), forced);
    ucal_setDefaultTimeZone(forced, status);
    free(forced);
}
static struct tm *traced_localtime(const time_t *value) {
    struct tm *result = localtime(value); timezone_trace_call("libc.localtime", forced_name); return result;
}
static struct tm *traced_localtime_r(const time_t *value, struct tm *result) {
    struct tm *converted = localtime_r(value, result); timezone_trace_call("libc.localtime_r", forced_name); return converted;
}
static time_t traced_mktime(struct tm *value) {
    time_t result = mktime(value); timezone_trace_call("libc.mktime", forced_name); return result;
}
static size_t traced_strftime(char *buffer, size_t capacity, const char *format, const struct tm *value) {
    size_t result = strftime(buffer, capacity, format, value); timezone_trace_call("libc.strftime", forced_name); return result;
}

INTERPOSE(locked_getenv, getenv);
INTERPOSE(locked_setenv, setenv);
INTERPOSE(locked_unsetenv, unsetenv);
INTERPOSE(locked_putenv, putenv);
INTERPOSE(locked_tzset, tzset);
INTERPOSE(locked_system, CFTimeZoneCopySystem);
INTERPOSE(locked_default, CFTimeZoneCopyDefault);
INTERPOSE(locked_set_default, CFTimeZoneSetDefault);
INTERPOSE(forced_icu_default, ucal_getDefaultTimeZone);
INTERPOSE(forced_icu_set_default, ucal_setDefaultTimeZone);
INTERPOSE(traced_localtime, localtime);
INTERPOSE(traced_localtime_r, localtime_r);
INTERPOSE(traced_mktime, mktime);
INTERPOSE(traced_strftime, strftime);

__attribute__((constructor)) static void install_hooks(void) {
    @autoreleasepool {
        const char *name = getenv("PROCESS_TIMEZONE");
        if (!name) {
            fprintf(stderr, "[timezone hooks] PROCESS_TIMEZONE required\n");
            abort();
        }
        NSString *canonical = canonical_timezone_name(@(name));
        forced_name = canonical ? strdup(canonical.UTF8String) : NULL;
        forced_ns_zone = canonical ? [NSTimeZone timeZoneWithName:canonical] : nil;
        if (!forced_ns_zone) {
            fprintf(stderr, "[timezone hooks] invalid timezone\n");
            abort();
        }
        forced_zone = (CFTimeZoneRef)CFRetain((__bridge CFTimeZoneRef)forced_ns_zone);
        if (timezone_files_configure(forced_name) != 0) {
            fprintf(stderr, "[timezone hooks] cannot resolve requested zoneinfo file\n");
            abort();
        }
        locked_tzset();
        locked_set_default(forced_zone);
        // CF internal calls may bypass public dyld interposition; test NS separately.
        for (NSString *selector in @[@"systemTimeZone", @"localTimeZone", @"defaultTimeZone"]) {
            Method method = class_getClassMethod(NSTimeZone.class, NSSelectorFromString(selector));
            method_setImplementation(method, (IMP)ns_forced);
        }
        method_setImplementation(class_getClassMethod(NSTimeZone.class, @selector(setDefaultTimeZone:)),
                                 (IMP)ns_ignore_default);
        Method urlResolve = class_getInstanceMethod([NSURL fileURLWithPath:@"/etc/localtime"].class, @selector(URLByResolvingSymlinksInPath));
        original_url_resolve = method_setImplementation(urlResolve, (IMP)forced_url_resolve);
        Method stringResolve = class_getInstanceMethod(NSString.class, @selector(stringByResolvingSymlinksInPath));
        original_string_resolve = method_setImplementation(stringResolve, (IMP)forced_string_resolve);
        timezone_trace_configure();
        atomic_store_explicit(&hooks_installed, 1, memory_order_release);
        timezone_trace_startup(forced_name);
        if (getenv("TIMEZONE_LAB_VERBOSE")) fprintf(stderr, "[timezone hooks] installed for %s\n", forced_name);
    }
}
