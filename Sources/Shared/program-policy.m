#import "program-policy.h"
#import "timezone-policy.h"
#include <fnmatch.h>
#include <unistd.h>
#include <errno.h>

BOOL TZWritePrivateData(NSData *data, NSString *path, NSError **error) {
    char *temporary = strdup([[path stringByAppendingString:@".XXXXXX"] fileSystemRepresentation]);
    int fd = mkstemp(temporary); // 0600 from creation, including the first write.
    int failure = fd < 0 ? errno : 0;
    const char *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (!failure && remaining) {
        ssize_t count = write(fd, bytes, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { failure = count < 0 ? errno : EIO; break; }
        bytes += count; remaining -= count;
    }
    if (fd >= 0 && close(fd) && !failure) failure = errno;
    if (!failure && rename(temporary, path.fileSystemRepresentation)) failure = errno;
    if (failure) {
        unlink(temporary);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
    }
    free(temporary);
    return !failure;
}

@implementation TZPolicyFile
+ (NSDictionary *)readFromDirectory:(NSString *)directory migrateLegacy:(BOOL)migrate error:(NSError **)error {
    NSString *path = [directory stringByAppendingPathComponent:@"policy.plist"];
    BOOL legacy = ![NSFileManager.defaultManager fileExistsAtPath:path];
    if (legacy) path = [directory stringByAppendingPathComponent:@"policy.json"];
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    NSDictionary *value = legacy ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error]
        : [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:error];
    if (!value || ![TZProgramPolicy policyWithDictionary:value error:error]) return nil;
    if (legacy && migrate && ![self write:value toDirectory:directory error:error]) return nil;
    return value;
}
+ (BOOL)write:(NSDictionary *)value toDirectory:(NSString *)directory error:(NSError **)error {
    if (![TZProgramPolicy policyWithDictionary:value error:error]) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    return data && TZWritePrivateData(data, [directory stringByAppendingPathComponent:@"policy.plist"], error);
}
@end

@implementation TZRule
- (NSDictionary *)dictionary {
    return @{@"id": self.identifier, @"name": self.name ?: self.pattern, @"kind": self.kind,
             @"pattern": self.pattern, @"mode": self.mode, @"zone": self.zone ?: @"",
             @"enabled": @(self.enabled), @"logging": @(self.logging), @"environment": self.environment ?: @{}};
}
@end
@implementation TZSession
- (id)copyWithZone:(NSZone *)zone {
    TZSession *copy = [TZSession new];
    copy.identifier = self.identifier; copy.ruleID = self.ruleID; copy.mode = self.mode;
    copy.zone = self.zone; copy.logging = self.logging; copy.ancestorRules = self.ancestorRules;
    copy.logRules = self.logRules;
    copy.baseline = self.baseline;
    copy.environment = self.environment;
    return copy;
}
@end
@implementation TZDecision
@end

@interface TZProgramPolicy ()
@property NSArray<TZRule *> *rules;
@property BOOL esEnabled;
@property NSString *defaultMode;
@property NSString *defaultZone;
@end

static BOOL matches(TZRule *rule, NSString *path) {
    if (!path.length) return NO;
    if ([rule.kind isEqual:@"app"])
        return [path hasPrefix:[rule.pattern stringByAppendingString:@"/"]];
    if ([rule.pattern containsString:@"*"] || [rule.pattern containsString:@"?"] || [rule.pattern containsString:@"["])
        return fnmatch(rule.pattern.fileSystemRepresentation, path.fileSystemRepresentation, FNM_PATHNAME) == 0;
    return [path isEqual:rule.pattern] || [path isEqual:rule.pattern.stringByResolvingSymlinksInPath];
}

static NSInteger specificity(TZRule *rule) {
    if ([rule.kind isEqual:@"app"]) return 10000 + rule.pattern.length;
    if (![rule.pattern containsString:@"*"] && ![rule.pattern containsString:@"?"] && ![rule.pattern containsString:@"["]) return 100000 + rule.pattern.length;
    return 20000 + [[rule.pattern componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"*?[]"]] componentsJoinedByString:@""].length;
}

@implementation TZProgramPolicy
+ (instancetype)policyWithDictionary:(NSDictionary *)dictionary error:(NSError **)error {
    if (![dictionary isKindOfClass:NSDictionary.class]) return [self fail:@"Policy must be an object" error:error];
    NSArray *entries = dictionary[@"rules"];
    // One-way migration of the working prototype's exact-path configuration.
    if (!entries && [dictionary[@"targets"] isKindOfClass:NSArray.class]) {
        NSMutableArray *legacy = [NSMutableArray new];
        for (NSString *path in dictionary[@"targets"])
            [legacy addObject:@{@"id": [@"legacy:" stringByAppendingString:path], @"kind": @"cli", @"pattern": path,
                @"mode": @"fixed", @"zone": dictionary[@"zone"] ?: @"Asia/Tokyo", @"enabled": @YES, @"logging": @NO}];
        entries = legacy;
    }
    if (![entries isKindOfClass:NSArray.class] || entries.count > 256) return [self fail:@"Expected at most 256 rules" error:error];
    NSMutableArray *rules = [NSMutableArray new];
    NSMutableSet *identifiers = [NSMutableSet new];
    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:NSDictionary.class]) return [self fail:@"Invalid rule" error:error];
        TZRule *rule = [TZRule new];
        rule.identifier = entry[@"id"];
        rule.name = entry[@"name"];
        rule.kind = entry[@"kind"];
        rule.pattern = entry[@"pattern"];
        rule.mode = entry[@"mode"];
        rule.enabled = entry[@"enabled"] ? [entry[@"enabled"] boolValue] : YES;
        rule.logging = [entry[@"logging"] boolValue];
        id environment = entry[@"environment"] ?: @{};
        if (![environment isKindOfClass:NSDictionary.class] || [environment count] > 64)
            return [self fail:@"Expected at most 64 environment variables per rule" error:error];
        NSUInteger environmentBytes = 0;
        NSCharacterSet *firstCharacters = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_"];
        NSCharacterSet *nameCharacters = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789"];
        for (id name in environment) {
            id value = environment[name];
            if (![name isKindOfClass:NSString.class] || ![name length] || [name length] > 128 ||
                ![firstCharacters characterIsMember:[name characterAtIndex:0]] ||
                [name rangeOfCharacterFromSet:nameCharacters.invertedSet].location != NSNotFound)
                return [self fail:@"Environment names must use letters, digits and underscores, and cannot start with a digit" error:error];
            if ([@[@"TZ", @"TZFILE", @"PROCESS_TIMEZONE", @"DYLD_INSERT_LIBRARIES"] containsObject:name] || [name hasPrefix:@"TIMEZONE_LAB_"])
                return [self fail:@"This environment variable is managed by Yoyo; use the time zone setting instead" error:error];
            if (![value isKindOfClass:NSString.class] || [value rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
                return [self fail:@"Environment values must be strings without NUL characters" error:error];
            environmentBytes += [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 2;
            if (environmentBytes > 32768) return [self fail:@"Environment variables must fit within 32 KiB per rule" error:error];
        }
        rule.environment = environment;
        if (![rule.identifier isKindOfClass:NSString.class] || !rule.identifier.length || [identifiers containsObject:rule.identifier] ||
            ![@[@"app", @"cli"] containsObject:rule.kind] || ![@[@"default", @"fixed", @"ask"] containsObject:rule.mode] ||
            ![rule.pattern isKindOfClass:NSString.class] || !rule.pattern.isAbsolutePath)
            return [self fail:@"Rule needs a unique ID, absolute path, kind and mode" error:error];
        if ([rule.kind isEqual:@"app"]) {
            rule.pattern = rule.pattern.stringByStandardizingPath;
            if (![rule.pattern.pathExtension.lowercaseString isEqual:@"app"])
                return [self fail:@"App scope must select a .app bundle" error:error];
        }
        if ([rule.mode isEqual:@"fixed"]) {
            rule.zone = canonical_timezone_name(entry[@"zone"]);
            if (!rule.zone) return [self fail:@"Fixed rules require an installed IANA timezone" error:error];
        } else rule.zone = canonical_timezone_name(entry[@"zone"]) ?: @"Asia/Tokyo";
        if (![rule.name isKindOfClass:NSString.class] || !rule.name.length) rule.name = rule.pattern.lastPathComponent;
        [identifiers addObject:rule.identifier]; [rules addObject:rule];
    }
    TZProgramPolicy *policy = [TZProgramPolicy new];
    policy.rules = rules; policy.esEnabled = dictionary[@"es_enabled"] ? [dictionary[@"es_enabled"] boolValue] : YES;
    policy.defaultMode = dictionary[@"default_mode"] ?: @"system";
    if (![@[@"system", @"fixed"] containsObject:policy.defaultMode]) return [self fail:@"Invalid default mode" error:error];
    policy.defaultZone = canonical_timezone_name(dictionary[@"default_zone"]) ?: @"";
    if ([policy.defaultMode isEqual:@"fixed"] && !policy.defaultZone.length) return [self fail:@"Default timezone must be an installed IANA timezone" error:error];
    return policy;
}
+ (instancetype)fail:(NSString *)message error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"TimezonePolicy" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}
- (NSDictionary *)dictionary {
    NSMutableArray *entries = [NSMutableArray new];
    for (TZRule *rule in self.rules) [entries addObject:rule.dictionary];
    return @{@"version": @2, @"es_enabled": @(self.esEnabled), @"rules": entries,
        @"default_mode": self.defaultMode, @"default_zone": self.defaultZone};
}
- (TZDecision *)decisionForPath:(NSString *)path invokedPath:(NSString *)invoked script:(NSString *)script parent:(TZSession *)parent {
    TZDecision *decision = [TZDecision new];
    if (!self.esEnabled) return decision;
    TZRule *selected = nil;
    NSInteger score = -1;
    for (TZRule *rule in self.rules) {
        if (!rule.enabled || !(matches(rule, path) || matches(rule, invoked) || matches(rule, script))) continue;
        NSInteger candidate = specificity(rule);
        if (candidate > score) { selected = rule; score = candidate; }
    }
    decision.rule = selected;
    // App subtree coverage already encountered in the chain is inherited scope,
    // not a reason to undo a more explicit child override.
    if (parent && (!selected || [parent.ancestorRules containsObject:selected.identifier])) {
        decision.session = [parent copy]; decision.inherited = YES;
        decision.session.logging |= selected.logging;
        if (selected) decision.session.logRules = [parent.logRules ?: [NSSet set] setByAddingObject:selected.identifier];
        return decision;
    }
    if (!selected) {
        if ([self.defaultMode isEqual:@"fixed"]) {
            TZSession *session = [TZSession new]; session.identifier = NSUUID.UUID.UUIDString;
            session.ruleID = @"@default"; session.mode = @"fixed"; session.zone = self.defaultZone;
            session.ancestorRules = [NSSet setWithObject:@"@default"]; session.logRules = [NSSet set];
            decision.session = session;
        }
        return decision;
    }
    TZSession *session = parent ? [parent copy] : [TZSession new];
    if (!session.identifier) session.identifier = NSUUID.UUID.UUIDString;
    session.ruleID = selected.identifier; session.mode = selected.mode; session.zone = selected.zone;
    NSMutableDictionary *environment = [parent.environment mutableCopy] ?: [NSMutableDictionary new];
    [environment addEntriesFromDictionary:selected.environment];
    session.environment = environment;
    session.logging = parent.logging || selected.logging;
    session.logRules = [parent.logRules ?: [NSSet set] setByAddingObject:selected.identifier];
    NSMutableSet *ancestors = [parent.ancestorRules mutableCopy] ?: [NSMutableSet new];
    [ancestors addObject:selected.identifier]; session.ancestorRules = ancestors;
    decision.session = session; decision.ask = [selected.mode isEqual:@"ask"];
    return decision;
}
- (BOOL)loggingEnabledForSession:(TZSession *)session {
    for (TZRule *rule in self.rules) if (rule.enabled && rule.logging && [session.logRules containsObject:rule.identifier]) return YES;
    return NO;
}
@end
