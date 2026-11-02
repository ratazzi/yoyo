#import <Foundation/Foundation.h>
#import "program-policy.h"
#include <unistd.h>

static NSString *root, *statePath;
static NSMutableArray *entries;
static NSDictionary *rule(NSString *name, NSString *pattern, NSString *mode, NSString *zone, BOOL logging) {
    return @{@"id": name, @"name": name, @"kind": @"cli", @"pattern": pattern, @"mode": mode,
        @"zone": zone, @"enabled": @YES, @"logging": @(logging)};
}
static BOOL apply_value(NSDictionary *value) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    if (![data writeToFile:statePath options:NSDataWritingAtomic error:nil]) return NO;
    // The daemon reloads once a second. Allow two ticks before starting the fixture.
    usleep(2100000); return YES;
}
static BOOL apply(void) { return apply_value(@{@"rules": entries, @"es_enabled": @YES}); }
static BOOL run(NSString *name, NSString *executable, NSArray *arguments) {
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:executable]; task.arguments = arguments;
    task.environment = @{@"TZ": @"Etc/UTC"}; NSError *error;
    BOOL launched = [task launchAndReturnError:&error]; if (launched) [task waitUntilExit];
    BOOL passed = launched && task.terminationStatus == 0;
    printf("%s: %s\n", name.UTF8String, passed ? "PASS" : "FAIL"); return passed;
}
int main(void) {
    @autoreleasepool {
        root = NSFileManager.defaultManager.currentDirectoryPath;
        statePath = [root stringByAppendingPathComponent:@"build/state/policy.plist"];
        NSData *original = [NSData dataWithContentsOfFile:statePath]; if (!original) return 2;
        NSDictionary *saved = [NSPropertyListSerialization propertyListWithData:original options:0 format:nil error:nil];
        TZProgramPolicy *policy = [TZProgramPolicy policyWithDictionary:saved error:nil];
        entries = [policy.dictionary[@"rules"] mutableCopy];
        NSString *base = [root stringByAppendingPathComponent:@"build/chain"], *parent = [base stringByAppendingPathComponent:@"parent"];
        NSString *child = [base stringByAppendingPathComponent:@"child-one"], *grand = [base stringByAppendingPathComponent:@"grand"];
        [entries addObject:rule(@"test-parent", parent, @"fixed", @"Asia/Tokyo", YES)];
        BOOL passed = YES;
        @try {
            passed &= apply() && run(@"unruled children inherit with empty env", parent, @[@"32400", @"1", @"--empty", child, @"32400", @"1", grand, @"32400", @"1"]);
            [entries addObject:rule(@"test-glob", [base stringByAppendingPathComponent:@"child-*"], @"fixed", @"America/New_York", NO)];
            passed &= apply() && run(@"glob override and grandchild inheritance", parent, @[@"32400", @"1", child, @"-18000", @"1", grand, @"-18000", @"1"]);
            [entries addObject:rule(@"test-default", child, @"default", @"Asia/Tokyo", NO)];
            passed &= apply() && run(@"exact default clears inherited hooks and restores TZ", parent, @[@"32400", @"1", child, @"0", @"0", grand, @"0", @"0"]);
            NSString *app = [base stringByAppendingPathComponent:@"Example.app"];
            [entries addObject:@{@"id": @"test-app", @"kind": @"app", @"pattern": app, @"mode": @"fixed", @"zone": @"Asia/Tokyo", @"enabled": @YES, @"logging": @NO}];
            passed &= apply() && run(@"app subtree executable", [app stringByAppendingPathComponent:@"Contents/Helpers/helper"], @[@"32400", @"1"]);
            passed &= apply_value(@{@"rules": entries, @"es_enabled": @YES, @"default_mode": @"fixed", @"default_zone": @"America/New_York"});
            passed &= run(@"global default applies to unmatched program", grand, @[@"-18000", @"1"]);
            passed &= run(@"system rule excludes program and descendants from global default", child, @[@"0", @"0", grand, @"0", @"0"]);
        } @finally {
            [original writeToFile:statePath options:NSDataWritingAtomic error:nil]; usleep(2100000);
        }
        NSString *log = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"build/state/behavior.jsonl"] encoding:NSUTF8StringEncoding error:nil];
        BOOL logs = [log containsString:@"\"type\":\"file\""] && [log containsString:@"\"type\":\"timezone\""] && ![log containsString:@"TEST_CONTENT_MUST_NOT_APPEAR_IN_BEHAVIOR_LOG"];
        printf("opt-in file/timezone metadata without file contents: %s\n", logs ? "PASS" : "FAIL");
        return passed && logs ? 0 : 1;
    }
}
