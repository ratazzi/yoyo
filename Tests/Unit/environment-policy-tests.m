#import <Foundation/Foundation.h>
#import "program-policy.h"
#include <assert.h>
#include <sys/stat.h>

static NSDictionary *entry(NSString *identifier, NSString *path, NSString *mode, id environment) {
    return @{@"id": identifier, @"kind": @"cli", @"pattern": path, @"mode": mode,
        @"zone": @"Asia/Tokyo", @"environment": environment};
}
static TZProgramPolicy *parse(NSArray *rules) {
    return [TZProgramPolicy policyWithDictionary:@{@"rules": rules, @"es_enabled": @YES} error:nil];
}
int main(void) {
    @autoreleasepool {
        NSDictionary *values = @{@"EXAMPLE": @"literal $HOME=a b", @"EMPTY": @"", @"UNICODE": @"你好"};
        NSDictionary *parentRule = entry(@"parent", @"/fixture/parent", @"default", values);
        NSDictionary *childRule = entry(@"child", @"/fixture/child", @"fixed", @{@"EXAMPLE": @"child", @"EXTRA": @"1"});
        TZProgramPolicy *policy = parse(@[parentRule, childRule]); assert(policy);
        TZSession *parent = [policy decisionForPath:@"/fixture/parent" invokedPath:nil script:nil parent:nil].session;
        assert([parent.mode isEqual:@"default"] && [parent.environment isEqual:values]);
        TZDecision *inherited = [policy decisionForPath:@"/fixture/unruled" invokedPath:nil script:nil parent:parent];
        assert(inherited.inherited && [inherited.session.environment isEqual:values]);
        TZSession *child = [policy decisionForPath:@"/fixture/child" invokedPath:nil script:nil parent:parent].session;
        assert([child.environment[@"EXAMPLE"] isEqual:@"child"] && [child.environment[@"EMPTY"] isEqual:@""]);
        assert([child.environment[@"EXTRA"] isEqual:@"1"] && [parent.environment[@"EXAMPLE"] isEqual:values[@"EXAMPLE"]]);
        TZSession *copy = [child copy];
        assert([copy.environment isEqual:child.environment]);
        TZSession *grandchild = [policy decisionForPath:@"/fixture/unruled" invokedPath:nil script:nil parent:child].session;
        assert([grandchild.environment isEqual:child.environment]);
        TZProgramPolicy *ask = parse(@[entry(@"ask", @"/fixture/ask", @"ask", values)]);
        TZDecision *prompt = [ask decisionForPath:@"/fixture/ask" invokedPath:nil script:nil parent:nil];
        assert(prompt.ask && [prompt.session.environment isEqual:values]);
        NSMutableDictionary *disabled = [parentRule mutableCopy]; disabled[@"enabled"] = @NO;
        assert(![parse(@[disabled]) decisionForPath:@"/fixture/parent" invokedPath:nil script:nil parent:nil].session);
        NSMutableDictionary *legacy = [parentRule mutableCopy]; [legacy removeObjectForKey:@"environment"];
        assert(parse(@[legacy]).rules.firstObject.environment.count == 0);
        for (NSString *name in @[@"", @"1NAME", @"A=B", @"HAS SPACE", @"变量", @"TZ", @"TZFILE", @"PROCESS_TIMEZONE", @"DYLD_INSERT_LIBRARIES", @"TIMEZONE_LAB_SESSION"]) {
            assert(!parse(@[entry(@"invalid", @"/fixture", @"default", @{name: @"value"})]));
        }
        assert(!parse(@[entry(@"invalid", @"/fixture", @"default", @{@"A": @1})]));
        assert(!parse(@[entry(@"invalid", @"/fixture", @"default", @[])]));
        assert(!parse(@[entry(@"invalid", @"/fixture", @"default", @{@"A": [NSString stringWithFormat:@"a%Cb", (unichar)0]})]));
        assert(!parse(@[entry(@"invalid", @"/fixture", @"default", @{@"A": [@"x" stringByPaddingToLength:32768 withString:@"x" startingAtIndex:0]})]));
        NSMutableDictionary *many = [NSMutableDictionary new];
        for (int i = 0; i < 65; i++) many[[NSString stringWithFormat:@"VAR%d", i]] = @"x";
        assert(!parse(@[entry(@"invalid", @"/fixture", @"default", many)]));

        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]);
        NSString *path = [directory stringByAppendingPathComponent:@"policy.plist"];
        for (int attempt = 0; attempt < 2; attempt++) {
            assert([TZPolicyFile write:policy.dictionary toDirectory:directory error:nil]);
            struct stat info; assert(!stat(path.fileSystemRepresentation, &info) && (info.st_mode & 0777) == 0600);
            NSDictionary *saved = [TZPolicyFile readFromDirectory:directory migrateLegacy:NO error:nil];
            assert([saved isEqual:policy.dictionary]);
            chmod(path.fileSystemRepresentation, 0644); // Replacing an old file must also restrict permissions.
        }
        assert([NSFileManager.defaultManager removeItemAtPath:directory error:nil]);
        puts("Rule environments: validation, legacy data, overrides, inheritance, ask mode and private persistence: PASS");
    }
    return 0;
}
