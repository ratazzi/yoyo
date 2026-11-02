#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <errno.h>
#include <poll.h>
#include <unistd.h>

static void require(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"AcceptanceFailure" reason:message userInfo:nil];
}

static NSMutableDictionary *read_policy(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSMutableDictionary *value = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:nil] : nil;
    require([value isKindOfClass:NSMutableDictionary.class], @"Cannot read policy");
    return value;
}

static void write_policy(NSString *path, NSDictionary *value) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    require(data && [data writeToFile:path options:NSDataWritingAtomic error:nil], @"Cannot write policy");
}

static NSString *read_line(NSFileHandle *handle) {
    NSMutableData *data = [NSMutableData new];
    double deadline = NSProcessInfo.processInfo.systemUptime + 10;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        struct pollfd descriptor = {handle.fileDescriptor, POLLIN, 0};
        int result = poll(&descriptor, 1, 100);
        if (result < 0 && errno == EINTR) continue;
        require(result >= 0, @"Cannot poll fixture output");
        if (!result) continue;
        char character;
        require(read(handle.fileDescriptor, &character, 1) == 1, @"Fixture exited before producing expected output");
        if (character == '\n') return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [data appendBytes:&character length:1];
        require(data.length < 4096, @"Unexpectedly long fixture output");
    }
    require(NO, @"Timed out waiting for fixture output");
    return nil;
}

static void expect(NSFileHandle *handle, NSString *line) {
    NSString *actual = read_line(handle);
    printf("%s\n", actual.UTF8String);
    require([actual isEqual:line], [NSString stringWithFormat:@"Expected %@; got %@", line, actual]);
}

static void wait_for_rule(NSString *statePath, NSString *app, BOOL present) {
    double deadline = NSProcessInfo.processInfo.systemUptime + 10;
    do {
        NSData *data = [NSData dataWithContentsOfFile:statePath];
        NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([state[@"status"] isEqual:@"listening"] && [state[@"targets"] containsObject:app] == present) return;
        usleep(100000);
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    require(NO, @"Daemon did not reload the temporary app rule");
}

static NSDictionary *daemon_state(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

static void add_rule(NSString *policyPath, NSString *identifier, NSString *app) {
    NSMutableDictionary *current = read_policy(policyPath);
    NSMutableArray *rules = [current[@"rules"] mutableCopy];
    require(rules != nil, @"Policy has no rules array");
    [rules addObject:@{@"id": identifier, @"name": @"Late Rule Acceptance", @"kind": @"app", @"pattern": app,
        @"mode": @"fixed", @"zone": @"Asia/Tokyo", @"enabled": @YES, @"logging": @NO}];
    current[@"rules"] = rules;
    write_policy(policyPath, current);
}

static void restart_ui(NSString *root, NSString *statePath) {
    NSURL *bundle = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"build/Yoyo.app"]];
    NSRunningApplication *old = nil;
    for (NSRunningApplication *candidate in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"yoyo.hola.ac"]) {
        if ([candidate.bundleURL.URLByStandardizingPath isEqual:bundle.URLByStandardizingPath]) { old = candidate; break; }
    }
    require(old != nil, @"Open this build of Yoyo before running UI restart acceptance");
    NSNumber *daemonPID = daemon_state(statePath)[@"pid"];
    require(daemonPID != nil, @"Missing daemon identity before UI restart");
    pid_t oldPID = old.processIdentifier;
    require([old terminate], @"Yoyo did not accept a normal quit request");
    double deadline = NSProcessInfo.processInfo.systemUptime + 10;
    while (!old.terminated && NSProcessInfo.processInfo.systemUptime < deadline)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    require(old.terminated, @"Yoyo did not quit within ten seconds");

    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = NO;
    __block BOOL finished = NO;
    __block NSRunningApplication *opened = nil;
    __block NSError *launchError = nil;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:bundle configuration:configuration
        completionHandler:^(NSRunningApplication *application, NSError *error) {
            opened = application; launchError = error; finished = YES;
        }];
    deadline = NSProcessInfo.processInfo.systemUptime + 10;
    while (!finished && NSProcessInfo.processInfo.systemUptime < deadline)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    require(finished && opened && !launchError && opened.processIdentifier != oldPID,
        launchError.localizedDescription ?: @"Yoyo did not reopen as a new process");
    NSDictionary *after = daemon_state(statePath);
    require([after[@"status"] isEqual:@"listening"] && [after[@"pid"] isEqual:daemonPID],
        @"Quitting/reopening Yoyo unexpectedly restarted or stopped the daemon");
    printf("Yoyo UI restarted: %d -> %d; daemon PID %d unchanged\n", oldPID, opened.processIdentifier, daemonPID.intValue);
}

static NSDictionary *inspect_process(NSString *root, pid_t pid) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"build/Yoyo.app/Contents/MacOS/Yoyo"]];
    task.arguments = @[@"--inspect-process", [NSString stringWithFormat:@"%d", pid]];
    NSPipe *output = [NSPipe pipe]; task.standardOutput = output;
    require([task launchAndReturnError:nil], @"Cannot launch signed process diagnostic");
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    require(reply[@"process"] != nil && !reply[@"error"], @"Process diagnostic unavailable");
    return [reply[@"process"] isKindOfClass:NSDictionary.class] ? reply[@"process"] : nil;
}

static void restart_daemon(NSString *root, NSString *statePath, pid_t parent, BOOL hasSession) {
    NSDictionary *before = inspect_process(root, parent);
    require((before != nil) == hasSession, @"Unexpected parent session before daemon restart");
    NSNumber *oldPID = daemon_state(statePath)[@"pid"];
    // The sudo wrapper restarts only the fixed Yoyo service. The fixture driver
    // stays under the original user, including policy writes and signed queries.
    printf("YOYO_TEST_RESTART_DAEMON\n"); fflush(stdout);
    struct pollfd input = {STDIN_FILENO, POLLIN, 0};
    require(poll(&input, 1, 35000) > 0, @"Timed out waiting for root restart driver");
    char acknowledgement = 0;
    require(read(STDIN_FILENO, &acknowledgement, 1) == 1 && acknowledgement == 'R', @"Root service restart failed");
    double deadline = NSProcessInfo.processInfo.systemUptime + 10;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        NSDictionary *current = daemon_state(statePath);
        if (![current[@"pid"] isEqual:oldPID] && [current[@"status"] isEqual:@"listening"]) break;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    NSDictionary *state = daemon_state(statePath);
    require([state[@"status"] isEqual:@"listening"] && ![state[@"pid"] isEqual:oldPID], @"ES daemon PID did not change");
    printf("ES daemon restarted: %d -> %d\n", oldPID.intValue, [state[@"pid"] intValue]);
    NSDictionary *after = inspect_process(root, parent);
    require((after != nil) == hasSession, @"Restart created or lost the parent's launch session");
    if (hasSession) for (NSString *key in @[@"session", @"mode", @"zone", @"rule_id", @"started_at", @"confirmation"])
        require([before[key] isEqual:after[key]], [@"Restored session changed " stringByAppendingString:key]);
    printf("Daemon restart preserved %s parent session\n", hasSession ? "existing" : "absence of");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        BOOL ruleBeforeLaunch = NO, restartUI = NO, restartDaemon = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--rule-before-launch")) ruleBeforeLaunch = YES;
            else if (!strcmp(argv[i], "--restart-ui")) restartUI = YES;
            else if (!strcmp(argv[i], "--restart-daemon")) restartDaemon = YES;
            else { fprintf(stderr, "Unknown option: %s\n", argv[i]); return 2; }
        }
        NSString *root = NSFileManager.defaultManager.currentDirectoryPath;
        NSString *policyPath = [root stringByAppendingPathComponent:@"build/state/policy.plist"];
        NSString *statePath = [root stringByAppendingPathComponent:@"build/state/daemon-state.json"];
        NSString *base = [root stringByAppendingPathComponent:@"build/tests/late-rule"];
        NSString *app = [base stringByAppendingPathComponent:@"LateRule.app"];
        NSString *identifier = [@"test-late-rule-" stringByAppendingString:NSUUID.UUID.UUIDString];
        BOOL added = NO, passed = NO;
        NSTask *parent = [NSTask new];
        @try {
            NSDictionary *initial = read_policy(policyPath);
            require([initial[@"es_enabled"] boolValue], @"Enable the ES service before running this test");
            require(![initial[@"default_mode"] isEqual:@"fixed"], @"This test requires System Default as the global default");
            wait_for_rule(statePath, app, NO);
            if (ruleBeforeLaunch) {
                added = YES; add_rule(policyPath, identifier, app);
                wait_for_rule(statePath, app, YES);
            }
            parent.executableURL = [NSURL fileURLWithPath:[app stringByAppendingPathComponent:@"Contents/MacOS/parent"]];
            parent.arguments = @[[base stringByAppendingPathComponent:@"outside"], [app stringByAppendingPathComponent:@"Contents/Helpers/helper"]];
            parent.environment = @{@"TZ": @"Etc/UTC"};
            NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe];
            parent.standardInput = input; parent.standardOutput = output;
            NSError *error = nil;
            require([parent launchAndReturnError:&error], error.localizedDescription ?: @"Cannot launch fixture");
            expect(output.fileHandleForReading, ruleBeforeLaunch ? @"parent-before offset=32400 TZ=Asia/Tokyo hook=1" : @"parent-before offset=0 TZ=Etc/UTC hook=0");

            if (!ruleBeforeLaunch) {
                added = YES; add_rule(policyPath, identifier, app);
                wait_for_rule(statePath, app, YES);
            }
            if (restartUI) restart_ui(root, statePath);
            if (restartDaemon) restart_daemon(root, statePath, parent.processIdentifier, ruleBeforeLaunch);
            [input.fileHandleForWriting writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
            [input.fileHandleForWriting closeFile];
            expect(output.fileHandleForReading, ruleBeforeLaunch ? @"parent-after offset=32400 TZ=Asia/Tokyo hook=1" : @"parent-after offset=0 TZ=Etc/UTC hook=0");
            expect(output.fileHandleForReading, ruleBeforeLaunch ? @"outside-direct-child offset=32400 TZ=Asia/Tokyo hook=1" : @"outside-direct-child offset=0 TZ=Etc/UTC hook=0");
            expect(output.fileHandleForReading, @"inside-app-helper offset=32400 TZ=Asia/Tokyo hook=1");
            expect(output.fileHandleForReading, @"outside-grandchild offset=32400 TZ=Asia/Tokyo hook=1");
            [parent waitUntilExit];
            require(parent.terminationStatus == 0, @"Fixture process chain failed");
            passed = YES;
        } @catch (NSException *error) {
            fprintf(stderr, "%s\n", error.reason.UTF8String);
        } @finally {
            if (parent.running) { [parent terminate]; [parent waitUntilExit]; }
            if (added) {
                @try {
                    NSMutableDictionary *current = read_policy(policyPath);
                    NSMutableArray *rules = [current[@"rules"] mutableCopy];
                    NSIndexSet *remove = [rules indexesOfObjectsPassingTest:^BOOL(NSDictionary *rule, NSUInteger index, BOOL *stop) {
                        return [rule[@"id"] isEqual:identifier];
                    }];
                    [rules removeObjectsAtIndexes:remove]; current[@"rules"] = rules;
                    write_policy(policyPath, current);
                    wait_for_rule(statePath, app, NO);
                } @catch (NSException *error) {
                    fprintf(stderr, "Cleanup failed: %s\n", error.reason.UTF8String); passed = NO;
                }
            }
        }
        printf("Rule %s parent launch%s%s: %s\n", ruleBeforeLaunch ? "before" : "after", restartUI ? ", Yoyo UI restarted" : "", restartDaemon ? ", daemon restarted" : "", passed ? "PASS" : "FAIL");
        return passed ? 0 : 1;
    }
}
