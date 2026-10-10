#import <AppKit/AppKit.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: launch absolute-app-path timezone absolute-output-path\n");
            return 2;
        }
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.createsNewApplicationInstance = YES;
        configuration.activates = NO;
        configuration.environment = @{
            @"TZ": @(argv[2]),
            @"TZ_PROBE_OUTPUT": @(argv[3])
        };
        [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:@(argv[1])]
                                           configuration:configuration
                                       completionHandler:^(NSRunningApplication *app, NSError *error) {
            if (error) fprintf(stderr, "%s\n", error.description.UTF8String);
            else printf("launched pid=%d\n", app.processIdentifier);
            exit(error ? 1 : 0);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fprintf(stderr, "Launch Services timeout\n");
            exit(3);
        });
        [NSRunLoop.currentRunLoop run];
    }
}
