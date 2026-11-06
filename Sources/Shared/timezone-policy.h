#pragma once
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <sys/stat.h>

// Canonicalize aliases using the same installed zoneinfo tree that supplies rules.
static inline NSString *canonical_timezone_name_in_directory(NSString *requested, NSString *directory) {
    if (![requested isKindOfClass:NSString.class] || ![NSTimeZone timeZoneWithName:requested]) return nil;
    char *resolvedDirectory = realpath(directory.fileSystemRepresentation, NULL);
    if (!resolvedDirectory) return nil;
    NSString *root = [@(resolvedDirectory) stringByAppendingString:@"/"];
    free(resolvedDirectory);
    NSString *path = [directory stringByAppendingPathComponent:requested];
    char *resolved = realpath(path.fileSystemRepresentation, NULL);
    if (!resolved) return nil;
    NSString *physical = @(resolved);
    struct stat metadata;
    BOOL regular = stat(resolved, &metadata) == 0 && S_ISREG(metadata.st_mode);
    free(resolved);
    if (!regular || ![physical hasPrefix:root]) return nil;
    NSString *canonical = [physical substringFromIndex:root.length];
    return [NSTimeZone timeZoneWithName:canonical] ? canonical : nil;
}

static inline NSString *canonical_timezone_name(NSString *requested) {
    return canonical_timezone_name_in_directory(requested, @"/var/db/timezone/zoneinfo");
}
