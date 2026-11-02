#import <Foundation/Foundation.h>
#include <unistd.h>

// Interactive smoke test: choose Asia/Tokyo in the app's launch request.
int main(void) {
    @autoreleasepool {
        NSString *root = NSFileManager.defaultManager.currentDirectoryPath;
        NSString *path = [root stringByAppendingPathComponent:@"build/state/policy.plist"];
        NSData *original = [NSData dataWithContentsOfFile:path]; if (!original) return 2;
        NSMutableDictionary *policy = [[NSPropertyListSerialization propertyListWithData:original options:NSPropertyListMutableContainers format:nil error:nil] mutableCopy];
        if (![policy[@"rules"] isKindOfClass:NSMutableArray.class]) return 2;
        NSString *fixture = [root stringByAppendingPathComponent:@"build/chain/grand"];
        [policy[@"rules"] addObject:@{@"id": NSUUID.UUID.UUIDString, @"name": @"Launch Test", @"kind": @"cli", @"pattern": fixture,
            @"mode": @"ask", @"zone": @"Asia/Tokyo", @"enabled": @YES, @"logging": @NO}];
        int result = 1;
        @try {
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:policy format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
            if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) return 2;
            usleep(2100000);
            NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:fixture]; task.arguments = @[@"32400", @"1"];
            task.environment = @{@"TZ": @"Etc/UTC"};
            if ([task launchAndReturnError:nil]) { [task waitUntilExit]; result = task.terminationStatus; }
        } @finally { [original writeToFile:path options:NSDataWritingAtomic error:nil]; }
        printf("Interactive launch request: %s\n", result == 0 ? "PASS" : "CANCELLED/FAILED"); return result;
    }
}
