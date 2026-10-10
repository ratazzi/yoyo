#pragma once
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <sys/stat.h>

// Canonicalize aliases using the same installed zoneinfo tree that supplies rules.
static inline NSString *canonical_timezone_name(NSString *requested) {
    if (![requested isKindOfClass:NSString.class] || ![NSTimeZone timeZoneWithName:requested]) return nil;
    NSString *path = [@"/var/db/timezone/zoneinfo" stringByAppendingPathComponent:requested];
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (!resolved) return nil;
    NSString *physical = @(resolved);
    struct stat metadata;
    BOOL regular = stat(resolved, &metadata) == 0 && S_ISREG(metadata.st_mode);
    free(resolved);
    NSRange marker = [physical rangeOfString:@"/zoneinfo/" options:NSBackwardsSearch];
    if (!regular || marker.location == NSNotFound) return nil;
    NSString *canonical = [physical substringFromIndex:NSMaxRange(marker)];
    return [NSTimeZone timeZoneWithName:canonical] ? canonical : nil;
}
