#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#include "timezone-policy.h"

static long startup_offset;
static BOOL startup_injected;

__attribute__((constructor)) static void capture_startup(void) {
    int (*ready)(void) = dlsym(RTLD_DEFAULT, "timezone_hooks_ready");
    startup_injected = ready && ready();
    time_t epoch = 0;
    struct tm value;
    startup_offset = localtime_r(&epoch, &value) ? value.tm_gmtoff : LONG_MIN;
}

static NSString *digest(NSData *data) {
    if (!data) return nil;
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *text = [NSMutableString new];
    for (unsigned i = 0; i < sizeof(bytes); i++) [text appendFormat:@"%02x", bytes[i]];
    return text;
}

static NSData *read_fd(int fd) {
    if (fd < 0) return nil;
    NSMutableData *data = [NSMutableData new];
    char buffer[4096];
    ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) != 0) {
        if (count < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return nil;
        }
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    close(fd);
    return data;
}

static NSString *zone_from_link(NSString *path) {
    NSRange marker = [path rangeOfString:@"/zoneinfo/"];
    return marker.location == NSNotFound ? nil : [path substringFromIndex:NSMaxRange(marker)];
}

static NSString *icu_zone(void) {
    void *icu = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LAZY | RTLD_LOCAL);
    int32_t (*get)(uint16_t *, int32_t, int32_t *) = icu ? dlsym(icu, "ucal_getDefaultTimeZone") : NULL;
    NSString *result = @"symbol unavailable";
    if (get) {
        uint16_t name[256]; int32_t error = 0;
        int32_t length = get(name, 256, &error);
        result = error <= 0 && length >= 0 && length < 256 ? [[NSString alloc] initWithCharacters:name length:length] :
            [NSString stringWithFormat:@"ICU error %d", error];
    }
    if (icu) dlclose(icu);
    return result;
}

static NSDictionary *api_values(void) {
    time_t epoch = 0;
    struct tm value;
    localtime_r(&epoch, &value);
    char formatted[128];
    strftime(formatted, sizeof(formatted), "%F %T %Z %z", &value);
    CFTimeZoneRef system = CFTimeZoneCopySystem();
    CFTimeZoneRef defaultZone = CFTimeZoneCopyDefault();
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
    NSMutableArray *samples = [NSMutableArray new];
    for (NSNumber *number in @[@(-1), @(1782864000LL), @(2208988800LL), @((long long)time(NULL))]) {
        time_t sample = (time_t)number.longLongValue;
        struct tm local;
        if (localtime_r(&sample, &local)) {
            time_t roundtrip = mktime(&local);
            [samples addObject:@{@"epoch": number, @"offset": @(local.tm_gmtoff),
                @"dst": @(local.tm_isdst), @"mktime_roundtrip": @(roundtrip == sample)}];
        }
    }
    NSDictionary *result = @{
        @"libc.localtime_r.offset": @(value.tm_gmtoff),
        @"libc.strftime": @(formatted),
        @"libc.localtime.offset": @(localtime(&epoch)->tm_gmtoff),
        @"libc.samples": samples,
        @"CF.system": (__bridge NSString *)CFTimeZoneGetName(system),
        @"CF.default": (__bridge NSString *)CFTimeZoneGetName(defaultZone),
        @"NS.system": NSTimeZone.systemTimeZone.name,
        @"NS.local": NSTimeZone.localTimeZone.name,
        @"NS.default": NSTimeZone.defaultTimeZone.name,
        @"NS.calendar": NSCalendar.currentCalendar.timeZone.name,
        @"NS.autoupdatingCalendar": NSCalendar.autoupdatingCurrentCalendar.timeZone.name,
        @"ICU.default": icu_zone(),
        @"NS.formatter": [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:0]]
    };
    CFRelease(system);
    CFRelease(defaultZone);
    return result;
}

static void file_record(NSMutableArray *records, NSString *source, NSData *data,
                        NSString *expectedHash, int error) {
    NSMutableDictionary *entry = [@{@"source": source, @"ok": @(data != nil)} mutableCopy];
    if (data) {
        entry[@"bytes"] = @(data.length);
        entry[@"sha256"] = digest(data);
        if (expectedHash) entry[@"matches_requested_zonefile"] = @([digest(data) isEqual:expectedHash]);
    } else {
        entry[@"errno"] = @(error);
        entry[@"error"] = @(strerror(error));
    }
    [records addObject:entry];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *expected = nil;
        BOOL requireInjected = NO, requireFiles = NO, attack = NO, scan = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--expect") && i + 1 < argc) expected = @(argv[++i]);
            else if (!strcmp(argv[i], "--require-injected")) requireInjected = YES;
            else if (!strcmp(argv[i], "--require-files")) requireFiles = YES;
            else if (!strcmp(argv[i], "--attack")) attack = YES;
            else if (!strcmp(argv[i], "--scan-zoneinfo")) scan = YES;
            else {
                fprintf(stderr, "usage: timezone-probe [--expect IANA/Zone] [--require-injected] [--require-files] [--attack] [--scan-zoneinfo]\n");
                return 2;
            }
        }
        NSString *inputZone = expected;
        if (expected) expected = canonical_timezone_name(expected);
        NSTimeZone *requested = expected ? [NSTimeZone timeZoneWithName:expected] : nil;
        if (inputZone && !requested) { fprintf(stderr, "invalid installed timezone\n"); return 2; }
        if (expected && !requested) { fprintf(stderr, "invalid timezone\n"); return 2; }
        if (requireFiles && !requested) { fprintf(stderr, "--require-files requires --expect\n"); return 2; }
        NSMutableDictionary *report = [@{
            @"pid": @(getpid()), @"injected_at_first_constructor": @(startup_injected),
            @"first_constructor_epoch_offset": @(startup_offset),
            @"environment_TZ": getenv("TZ") ? @(getenv("TZ")) : NSNull.null,
            @"environment_TZFILE": getenv("TZFILE") ? @(getenv("TZFILE")) : NSNull.null,
            @"initial_apis": api_values()
        } mutableCopy];
        NSMutableArray *paths = [NSMutableArray new];
        char buffer[PATH_MAX + 1];
        ssize_t n = readlink("/etc/localtime", buffer, PATH_MAX);
        NSString *link = n >= 0 ? [[NSString alloc] initWithBytes:buffer length:n encoding:NSUTF8StringEncoding] : nil;
        [paths addObject:@{@"source": @"readlink", @"value": link ?: (id)NSNull.null, @"errno": @(n < 0 ? errno : 0)}];
        char *resolved = realpath("/etc/localtime", NULL);
        [paths addObject:@{@"source": @"realpath", @"value": resolved ? @(resolved) : (id)NSNull.null,
                           @"errno": @(resolved ? 0 : errno)}];
        free(resolved);
        NSString *fmLink = [NSFileManager.defaultManager destinationOfSymbolicLinkAtPath:@"/etc/localtime" error:nil];
        [paths addObject:@{@"source": @"NSFileManager.readlink", @"value": fmLink ?: (id)NSNull.null}];
        [paths addObject:@{@"source": @"NSURL.resolveSymlinks", @"value": [NSURL fileURLWithPath:@"/etc/localtime"].URLByResolvingSymlinksInPath.path}];
        [paths addObject:@{@"source": @"NSString.resolveSymlinks", @"value": @"/etc/localtime".stringByResolvingSymlinksInPath}];
        int etc = open("/etc", O_RDONLY | O_DIRECTORY);
        n = etc >= 0 ? readlinkat(etc, "localtime", buffer, PATH_MAX) : -1;
        [paths addObject:@{@"source": @"readlinkat", @"value": n >= 0 ? [[NSString alloc] initWithBytes:buffer length:n encoding:NSUTF8StringEncoding] : (id)NSNull.null,
                           @"errno": @(n < 0 ? errno : 0)}];
        // This intentionally tests the exported syscall trampoline, independently of open/readlink hooks.
        n = syscall(SYS_readlink, "/etc/localtime", buffer, PATH_MAX);
        [paths addObject:@{@"source": @"syscall.readlink", @"value": n >= 0 ? [[NSString alloc] initWithBytes:buffer length:n encoding:NSUTF8StringEncoding] : (id)NSNull.null,
                           @"errno": @(n < 0 ? errno : 0)}];
        report[@"path_reads"] = paths;
        NSString *zoneRoot = @"/var/db/timezone/zoneinfo";
        NSData *requestedData = expected ? [NSData dataWithContentsOfFile:[zoneRoot stringByAppendingPathComponent:expected]] : nil;
        NSString *expectedHash = digest(requestedData);
        NSMutableArray *files = [NSMutableArray new];
        NSData *direct = read_fd(open("/etc/localtime", O_RDONLY));
        file_record(files, @"open+read", direct, expectedHash, errno);
        NSData *relative = etc >= 0 ? read_fd(openat(etc, "localtime", O_RDONLY)) : nil;
        file_record(files, @"openat+read", relative, expectedHash, errno);
        if (etc >= 0) close(etc);
        file_record(files, @"Foundation.NSData", [NSData dataWithContentsOfFile:@"/etc/localtime"], expectedHash, errno);
        FILE *stream = fopen("/etc/localtime", "rb");
        NSMutableData *stdioData = stream ? [NSMutableData new] : nil;
        if (stream) {
            size_t count;
            while ((count = fread(buffer, 1, sizeof(buffer), stream))) [stdioData appendBytes:buffer length:count];
            if (ferror(stream)) stdioData = nil;
            fclose(stream);
        }
        file_record(files, @"fopen+fread", stdioData, expectedHash, errno);
        int fd = open("/etc/localtime", O_RDONLY);
        if (fd >= 0 && fcntl(fd, F_GETPATH, buffer) == 0)
            [paths addObject:@{@"source": @"fcntl.F_GETPATH", @"value": @(buffer)}];
        struct stat st;
        NSData *mappedData = nil;
        if (fd >= 0 && fstat(fd, &st) == 0 && st.st_size > 0) {
            void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
            if (map != MAP_FAILED) {
                mappedData = [NSData dataWithBytes:map length:(NSUInteger)st.st_size];
                munmap(map, (size_t)st.st_size);
            }
        }
        if (fd >= 0) close(fd);
        file_record(files, @"open+mmap", mappedData, expectedHash, errno);
        file_record(files, @"syscall.open+read", read_fd((int)syscall(SYS_open, "/etc/localtime", O_RDONLY, 0)), expectedHash, errno);
        report[@"file_reads"] = files;
        struct stat referenceStat, pathStat;
        BOOL metadata = expected && stat([zoneRoot stringByAppendingPathComponent:expected].fileSystemRepresentation, &referenceStat) == 0;
        BOOL statMatches = metadata && stat("/etc/localtime", &pathStat) == 0 && pathStat.st_size == referenceStat.st_size;
        BOOL rawStatMatches = metadata && syscall(SYS_stat64, "/etc/localtime", &pathStat) == 0 && pathStat.st_size == referenceStat.st_size;
        report[@"metadata_reads"] = @{@"stat_matches_requested_zonefile": @(statMatches), @"syscall.stat64_matches_requested_zonefile": @(rawStatMatches)};
        if (link) report[@"zone_from_localtime_symlink"] = zone_from_link(link) ?: (id)NSNull.null;
        if (scan && direct) {
            NSMutableArray *matches = [NSMutableArray new];
            for (NSString *relativePath in [NSFileManager.defaultManager enumeratorAtPath:zoneRoot]) {
                NSString *path = [zoneRoot stringByAppendingPathComponent:relativePath];
                NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
                if ([attributes[NSFileType] isEqual:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] == direct.length) {
                    NSData *candidate = [NSData dataWithContentsOfFile:path];
                    if ([candidate isEqual:direct]) [matches addObject:relativePath];
                }
            }
            report[@"zoneinfo_content_matches"] = matches;
        }
        NSMutableArray *attempts = [NSMutableArray new];
        if (attack) {
            unsetenv("TZ"); tzset(); [NSTimeZone resetSystemTimeZone];
            [attempts addObject:@{@"attempt": @"unset TZ + reset", @"apis": api_values()}];
            setenv("TZ", "America/New_York", 1); tzset(); CFTimeZoneResetSystem();
            [attempts addObject:@{@"attempt": @"TZ New_York + reset", @"apis": api_values()}];
            static char entry[] = "TZ=UTC";
            putenv(entry); tzset();
            NSTimeZone.defaultTimeZone = [NSTimeZone timeZoneWithName:@"UTC"];
            [attempts addObject:@{@"attempt": @"putenv UTC + set NS default", @"apis": api_values()}];
            void *icu = dlopen("/usr/lib/libicucore.A.dylib", RTLD_LAZY | RTLD_LOCAL);
            void (*set)(const uint16_t *, int32_t *) = icu ? dlsym(icu, "ucal_setDefaultTimeZone") : NULL;
            if (set) {
                const uint16_t utc[] = {'U', 'T', 'C', 0}; int32_t error = 0;
                set(utc, &error);
                [attempts addObject:@{@"attempt": @"set ICU default UTC", @"icu_status": @(error), @"apis": api_values()}];
            }
            if (icu) dlclose(icu);
            setenv("TZFILE", "/var/db/timezone/zoneinfo/Australia/Melbourne", 1);
            tzset(); CFTimeZoneResetSystem();
            [attempts addObject:@{@"attempt": @"set TZFILE to host zone + reset", @"apis": api_values()}];
        }
        report[@"mutation_attempts"] = attempts;
        report[@"ICU.default"] = icu_zone();
        BOOL pass = !requireInjected || startup_injected;
        if (requested) {
            BOOL apiNames = YES;
            NSInteger offset = [requested secondsFromGMTForDate:[NSDate dateWithTimeIntervalSince1970:0]];
            pass &= startup_offset == offset;
            NSMutableArray *all = [NSMutableArray arrayWithObject:report[@"initial_apis"]];
            NSDateFormatter *reference = [NSDateFormatter new];
            reference.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
            reference.timeZone = requested;
            NSString *expectedDate = [reference stringFromDate:[NSDate dateWithTimeIntervalSince1970:0]];
            for (NSDictionary *attempt in attempts) [all addObject:attempt[@"apis"]];
            for (NSDictionary *values in all) {
                pass &= [values[@"libc.localtime_r.offset"] longValue] == offset;
                pass &= [values[@"libc.localtime.offset"] longValue] == offset;
                pass &= [values[@"NS.formatter"] isEqual:expectedDate];
                for (NSString *key in @[@"CF.system", @"CF.default", @"NS.system", @"NS.local", @"NS.default", @"NS.calendar", @"NS.autoupdatingCalendar", @"ICU.default"]) {
                    BOOL match = [values[key] isEqual:expected];
                    pass &= match; apiNames &= match;
                }
                pass &= [values[@"libc.samples"] count] == 4;
                for (NSDictionary *sample in values[@"libc.samples"]) {
                    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[sample[@"epoch"] doubleValue]];
                    pass &= [sample[@"offset"] integerValue] == [requested secondsFromGMTForDate:date];
                    pass &= [sample[@"mktime_roundtrip"] boolValue];
                }
            }
            report[@"requested_zone"] = expected;
            report[@"input_zone"] = inputZone;
            report[@"default_api_checks_pass"] = @(pass);
            BOOL namePass = YES;
            for (NSDictionary *entry in paths) {
                NSString *path = entry[@"value"];
                namePass &= [path isKindOfClass:NSString.class] && [zone_from_link(path) isEqual:expected];
            }
            report[@"all_path_reads_match_requested_zone"] = @(namePass);
            report[@"icu_name_matches_requested_zone"] = @([report[@"ICU.default"] isEqual:expected]);
            report[@"all_timezone_names_match_requested_zone"] = @((BOOL)(apiNames && namePass && [report[@"icu_name_matches_requested_zone"] boolValue]));
            BOOL filePass = expectedHash != nil;
            for (NSDictionary *entry in files) filePass &= [entry[@"matches_requested_zonefile"] boolValue];
            report[@"all_file_reads_match_requested_zone"] = @(filePass);
            report[@"all_file_data_and_metadata_match_requested_zone"] = @((BOOL)(filePass && statMatches && rawStatMatches));
            if (requireFiles) pass &= filePass && namePass && statMatches && rawStatMatches && [report[@"icu_name_matches_requested_zone"] boolValue];
            // File leaks are reported independently; default API acceptance is not full virtualization.
        }
        report[@"acceptance_pass"] = @(pass);
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
        return pass ? 0 : 1;
    }
}
