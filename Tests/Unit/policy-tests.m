#import <Foundation/Foundation.h>
#import "program-policy.h"
#include <assert.h>

static NSDictionary *rule(NSString *identifier, NSString *kind, NSString *pattern, NSString *mode, NSString *zone) {
    return @{@"id": identifier, @"kind": kind, @"pattern": pattern, @"mode": mode, @"zone": zone, @"enabled": @YES, @"logging": @NO};
}
int main(void) {
    @autoreleasepool {
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *legacyPath = [directory stringByAppendingPathComponent:@"policy.json"];
        NSString *plistPath = [directory stringByAppendingPathComponent:@"policy.plist"];
        NSDictionary *legacy = @{@"rules": @[rule(@"stored", @"cli", @"/usr/bin/example", @"fixed", @"Asia/Tokyo")], @"es_enabled": @YES};
        NSData *legacyData = [NSJSONSerialization dataWithJSONObject:legacy options:0 error:nil];
        assert([legacyData writeToFile:legacyPath atomically:YES]);
        assert([[TZPolicyFile readFromDirectory:directory migrateLegacy:NO error:nil] isEqual:legacy]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:plistPath]);
        assert([[TZPolicyFile readFromDirectory:directory migrateLegacy:YES error:nil] isEqual:legacy]);
        assert([[NSData dataWithContentsOfFile:legacyPath] isEqual:legacyData]);
        NSPropertyListFormat format;
        NSDictionary *migratedValue = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:plistPath] options:0 format:&format error:nil];
        assert([migratedValue isEqual:legacy] && format == NSPropertyListXMLFormat_v1_0);
        NSDictionary *disabled = @{@"rules": @[], @"es_enabled": @NO};
        assert([TZPolicyFile write:disabled toDirectory:directory error:nil]);
        assert([[TZPolicyFile readFromDirectory:directory migrateLegacy:YES error:nil] isEqual:disabled]);
        assert(![TZPolicyFile write:@{@"rules": @"invalid"} toDirectory:directory error:nil]);
        assert([[TZPolicyFile readFromDirectory:directory migrateLegacy:NO error:nil] isEqual:disabled]);
        assert([[@"broken plist" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:plistPath atomically:YES]);
        NSError *readError = nil;
        assert(![TZPolicyFile readFromDirectory:directory migrateLegacy:YES error:&readError] && readError);
        assert([NSFileManager.defaultManager removeItemAtPath:plistPath error:nil]);
        // Invalid legacy data must not create a plist or destroy the backup.
        assert([[@"not json" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:legacyPath atomically:YES]);
        assert(![TZPolicyFile readFromDirectory:directory migrateLegacy:YES error:nil]);
        assert(![NSFileManager.defaultManager fileExistsAtPath:plistPath]);
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
        puts("Policy storage: XML plist, legacy migration, precedence and invalid-file preservation: PASS");
        NSArray *rules = @[
            rule(@"app", @"app", @"/Applications/Example.app", @"ask", @"Asia/Tokyo"),
            rule(@"child-default", @"cli", @"/Applications/Example.app/Contents/MacOS/Helper", @"default", @""),
            rule(@"glob", @"cli", @"/opt/tools/*/bin/python*", @"fixed", @"America/New_York"),
            rule(@"exact", @"cli", @"/opt/tools/3/bin/python3", @"fixed", @"Asia/Tokyo")
        ];
        TZProgramPolicy *policy = [TZProgramPolicy policyWithDictionary:@{@"rules": rules} error:nil]; assert(policy);
        TZDecision *root = [policy decisionForPath:@"/Applications/Example.app/Contents/MacOS/Main" invokedPath:nil script:nil parent:nil];
        assert(root.ask);
        root.session.mode = @"fixed"; root.session.zone = @"Asia/Tokyo";
        TZDecision *helper = [policy decisionForPath:@"/Applications/Example.app/Contents/Frameworks/Worker" invokedPath:nil script:nil parent:root.session];
        assert(helper.inherited && !helper.ask && [helper.session.zone isEqual:@"Asia/Tokyo"]);
        TZDecision *outside = [policy decisionForPath:@"/usr/bin/child" invokedPath:nil script:nil parent:root.session];
        assert(outside.inherited && [outside.session.identifier isEqual:root.session.identifier]);
        TZDecision *childDefault = [policy decisionForPath:@"/Applications/Example.app/Contents/MacOS/Helper" invokedPath:nil script:nil parent:root.session];
        assert(!childDefault.inherited && [childDefault.session.mode isEqual:@"default"]);
        TZDecision *grandchild = [policy decisionForPath:@"/Applications/Example.app/Contents/Frameworks/Worker" invokedPath:nil script:nil parent:childDefault.session];
        assert(grandchild.inherited && [grandchild.session.mode isEqual:@"default"]);
        TZDecision *glob = [policy decisionForPath:@"/opt/tools/4/bin/python3" invokedPath:nil script:nil parent:nil];
        assert([glob.session.zone isEqual:@"America/New_York"]);
        TZDecision *exact = [policy decisionForPath:@"/opt/tools/3/bin/python3" invokedPath:nil script:nil parent:nil];
        assert([exact.session.zone isEqual:@"Asia/Tokyo"]);
        assert(![policy decisionForPath:@"/Applications/Example.app.backup/Contents/MacOS/Main" invokedPath:nil script:nil parent:nil].session);
        assert(![policy decisionForPath:@"/usr/bin/unmatched" invokedPath:nil script:nil parent:nil].session);
        TZProgramPolicy *off = [TZProgramPolicy policyWithDictionary:@{@"rules": rules, @"es_enabled": @NO} error:nil];
        assert(![off decisionForPath:@"/opt/tools/3/bin/python3" invokedPath:nil script:nil parent:nil].session);
        // Adding an app rule cannot create a launch session for an existing parent.
        NSString *lateApp = @"/Applications/LateRule.app";
        TZProgramPolicy *before = [TZProgramPolicy policyWithDictionary:@{@"rules": @[]} error:nil];
        TZDecision *existingParent = [before decisionForPath:[lateApp stringByAppendingPathComponent:@"Contents/MacOS/Main"] invokedPath:nil script:nil parent:nil];
        assert(!existingParent.session);
        TZProgramPolicy *after = [TZProgramPolicy policyWithDictionary:@{@"rules": @[
            rule(@"late-app", @"app", lateApp, @"fixed", @"Asia/Tokyo")]} error:nil];
        TZDecision *outsideAfterAdd = [after decisionForPath:@"/opt/tools/outside" invokedPath:nil script:nil parent:existingParent.session];
        assert(!outsideAfterAdd.session);
        TZDecision *helperAfterAdd = [after decisionForPath:[lateApp stringByAppendingPathComponent:@"Contents/Helpers/Worker"] invokedPath:nil script:nil parent:existingParent.session];
        assert(!helperAfterAdd.inherited && [helperAfterAdd.session.zone isEqual:@"Asia/Tokyo"]);
        TZDecision *grandchildAfterAdd = [after decisionForPath:@"/opt/tools/outside" invokedPath:nil script:nil parent:helperAfterAdd.session];
        assert(grandchildAfterAdd.inherited && [grandchildAfterAdd.session.identifier isEqual:helperAfterAdd.session.identifier]);
        assert(!existingParent.session);
        assert(![TZProgramPolicy policyWithDictionary:@{@"rules": @[rule(@"bad", @"cli", @"/tmp/x", @"fixed", @"Bogus/Zone")]} error:nil]);
        TZProgramPolicy *migrated = [TZProgramPolicy policyWithDictionary:@{@"targets": @[@"/bin/date"], @"zone": @"Asia/Tokyo"} error:nil];
        assert(migrated.rules.count == 1 && [migrated.rules[0].mode isEqual:@"fixed"]);
        TZProgramPolicy *global = [TZProgramPolicy policyWithDictionary:@{@"rules": rules, @"default_mode": @"fixed", @"default_zone": @"Europe/London"} error:nil];
        TZDecision *fallback = [global decisionForPath:@"/usr/bin/unmatched" invokedPath:nil script:nil parent:nil];
        assert([fallback.session.mode isEqual:@"fixed"] && [fallback.session.zone isEqual:@"Europe/London"]);
        assert([fallback.session.ruleID isEqual:@"@default"] && ![global loggingEnabledForSession:fallback.session]);
        TZDecision *excluded = [global decisionForPath:@"/Applications/Example.app/Contents/MacOS/Helper" invokedPath:nil script:nil parent:fallback.session];
        assert([excluded.session.mode isEqual:@"default"] && !excluded.inherited);
        TZDecision *excludedChild = [global decisionForPath:@"/usr/bin/unmatched" invokedPath:nil script:nil parent:excluded.session];
        assert(excludedChild.inherited && [excludedChild.session.mode isEqual:@"default"]);
        TZDecision *fixedChild = [global decisionForPath:@"/usr/bin/unmatched" invokedPath:nil script:nil parent:root.session];
        assert([fixedChild.session.zone isEqual:@"Asia/Tokyo"]);
        assert((![TZProgramPolicy policyWithDictionary:@{@"rules": @[], @"default_mode": @"fixed", @"default_zone": @"Bogus/Zone"} error:nil]));
        TZProgramPolicy *roundtrip = [TZProgramPolicy policyWithDictionary:global.dictionary error:nil];
        assert([roundtrip.defaultMode isEqual:@"fixed"] && [roundtrip.defaultZone isEqual:@"Europe/London"]);
        puts("Rule precedence, .app scope, glob, default, session inheritance and legacy migration: PASS");
        puts("Global default, system exclusion, descendant inheritance and persistence: PASS");
        puts("Late app rule: existing parent unchanged, outside child unchanged, new helper matched and descendants inherit: PASS");
    }
    return 0;
}
