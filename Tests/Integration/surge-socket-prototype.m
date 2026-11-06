#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <libproc.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef YOYO_LOCAL_SOCKET_TEST
#import "../../Sources/App/SurgeSocketPrototype.h"
#include <mach/mach.h>
#endif

static void require(BOOL value, NSString *message) {
    if (!value) @throw [NSException exceptionWithName:@"TestFailure" reason:message userInfo:nil];
}
static int connect_to(int port, int type) {
    int fd = socket(AF_INET, type, 0);
    require(fd >= 0, @"socket failed");
    struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET, .sin_port = htons(port)};
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    require(connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0, @"connect failed");
    return fd;
}
static NSDictionary *post(NSDictionary *payload) {
#ifdef YOYO_LOCAL_SOCKET_TEST
    return TZSurgeSocketCandidates(payload);
#else
    int fd = connect_to(47643, SOCK_STREAM);
    NSMutableDictionary *reported = [payload mutableCopy];
    if (getenv("YOYO_EXPECT_ROUTE") && !reported[@"argument"]) reported[@"argument"] = @(getenv("YOYO_EXPECT_ROUTE"));
    NSData *body = [NSJSONSerialization dataWithJSONObject:reported options:0 error:nil];
    NSString *header = [NSString stringWithFormat:@"POST /v1/surge/request HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", body.length];
    NSMutableData *request = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]; [request appendData:body];
    const char *bytes = request.bytes; size_t remaining = request.length;
    while (remaining) { ssize_t n = write(fd, bytes, remaining); require(n > 0, @"write failed"); bytes += n; remaining -= n; }
    NSMutableData *response = [NSMutableData new]; char buffer[4096]; ssize_t n;
    while ((n = read(fd, buffer, sizeof(buffer))) > 0) [response appendBytes:buffer length:n];
    close(fd);
    NSData *delimiter = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange split = [response rangeOfData:delimiter options:0 range:NSMakeRange(0, response.length)];
    require(split.location != NSNotFound, @"invalid HTTP response");
    NSDictionary *value = [NSJSONSerialization JSONObjectWithData:[response subdataWithRange:NSMakeRange(NSMaxRange(split), response.length - NSMaxRange(split))] options:0 error:nil];
    require(value[@"result"] != nil, @"missing lookup result");
    if (getenv("YOYO_EXPECT_ROUTE")) {
        if ([value[@"result"][@"status"] isEqual:@"socket_unique"]) {
            BOOL expectedMatch = [reported[@"argument"] isEqual:@(getenv("YOYO_EXPECT_ROUTE"))];
            require([value[@"timezone"] isEqual:@(getenv("YOYO_EXPECT_ZONE"))] && [value[@"matched"] boolValue] == expectedMatch, [value description]);
            require([value[@"routing"][@"zone"] isEqual:@(getenv("YOYO_EXPECT_ZONE"))], [value description]);
        } else {
            require(value[@"timezone"] == NSNull.null && ![value[@"matched"] boolValue], @"Ambiguous or missing socket must not return a timezone");
        }
    }
    return value[@"result"];
#endif
}
static int local_port(int fd) {
    struct sockaddr_in address; socklen_t size = sizeof(address);
    require(getsockname(fd, (struct sockaddr *)&address, &size) == 0, @"getsockname failed");
    return ntohs(address.sin_port);
}

int main(void) {
    @autoreleasepool {
        alarm(20); pid_t child = -1;
        @try {
            int listener = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET};
            inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
            require(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(listener, 4) == 0, @"listen failed");
            int port = local_port(listener), client = connect_to(port, SOCK_STREAM);
            char path[PROC_PIDPATHINFO_MAXSIZE]; require(proc_pidpath(getpid(), path, sizeof(path)) > 0, @"path lookup failed");
            NSMutableDictionary *payload = [@{@"processPath": @(path), @"sourcePort": @(local_port(client)), @"sourceIP": @"127.0.0.1",
                @"hostname": @"example.test", @"destPort": @443, @"protocol": @"HTTPS", @"listenPort": @(port)} mutableCopy];
            NSDictionary *result = post(payload);
            require([result[@"status"] isEqual:@"socket_unique"] && [result[@"pid"] intValue] == getpid(), [result description]);
            puts("TCP proxy tuple -> exact PID: PASS");
            NSMutableDictionary *vif = [payload mutableCopy];
            [vif removeObjectForKey:@"listenPort"];
            vif[@"destPort"] = @(port);
            result = post(vif);
            require([result[@"status"] isEqual:@"socket_unique"] && [result[@"pid"] intValue] == getpid(), [result description]);
            require([result[@"candidates"][0][@"sockets"][0][@"evidence"] isEqual:@"source_tuple"], [result description]);
            puts("Missing destination metadata, unique source tuple -> exact PID: PASS");
#ifdef YOYO_LOCAL_SOCKET_TEST
            NSDictionary *sourceCandidate = result[@"candidates"][0];
            audit_token_t token; mach_msg_type_number_t tokenCount = TASK_AUDIT_TOKEN_COUNT;
            require(task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &tokenCount) == KERN_SUCCESS, @"audit token failed");
            NSMutableDictionary *session = [sourceCandidate mutableCopy]; session[@"pidversion"] = @(token.val[7]);
            require(TZSurgeSessionIsCurrent(sourceCandidate, session), @"Source tuple must pass live identity revalidation");
            NSMutableDictionary *stale = [sourceCandidate mutableCopy];
            NSMutableDictionary *staleSocket = [sourceCandidate[@"sockets"][0] mutableCopy];
            staleSocket[@"generation"] = @0; stale[@"sockets"] = @[staleSocket];
            require(!TZSurgeSessionIsCurrent(stale, session), @"Stale socket must fail identity revalidation");
#endif
            for (NSString *field in @[@"sourceIP", @"protocol", @"destPort", @"hostname", @"dnsResult"]) {
                NSMutableDictionary *invalid = [vif mutableCopy];
                if ([field isEqual:@"sourceIP"] || [field isEqual:@"protocol"]) [invalid removeObjectForKey:field];
                else if ([field isEqual:@"destPort"]) invalid[field] = @0;
                else if ([field isEqual:@"hostname"]) invalid[field] = @"192.0.2.1";
                else invalid[field] = @{@"v4Addresses": @[@"192.0.2.1"]};
                result = post(invalid);
                require(result[@"pid"] == NSNull.null, [result description]);
            }
            puts("Missing source metadata or conflicting destination -> no guessed PID: PASS");
            if (getenv("YOYO_EXPECT_ROUTE")) {
                NSMutableDictionary *wrong = [payload mutableCopy]; wrong[@"argument"] = @"Wrong_Zone";
                post(wrong);
                puts("Known launch timezone, different argument -> unmatched: PASS");
            }

            NSMutableDictionary *pathOnly = [payload mutableCopy]; [pathOnly removeObjectForKey:@"sourcePort"];
            result = post(pathOnly);
            require([result[@"status"] isEqual:@"path_only"] && result[@"pid"] == NSNull.null, [result description]);
            puts("Missing source port never becomes confirmed PID: PASS");

            child = fork(); require(child >= 0, @"fork failed");
            if (!child) { for (;;) pause(); }
            result = post(payload);
            require([result[@"status"] isEqual:@"ambiguous"] && result[@"pid"] == NSNull.null && [result[@"candidates"] count] == 2, [result description]);
            puts("Two processes sharing a socket -> ambiguous, no guessed PID: PASS");
            result = post(vif);
            require([result[@"status"] isEqual:@"ambiguous"] && result[@"pid"] == NSNull.null, [result description]);
            puts("Shared source tuple -> ambiguous: PASS");
            kill(child, SIGTERM); waitpid(child, NULL, 0); child = -1;

            int udp = connect_to(port, SOCK_DGRAM);
            NSMutableDictionary *datagram = [payload mutableCopy]; datagram[@"protocol"] = @"UDP"; datagram[@"sourcePort"] = @(local_port(udp));
            result = post(datagram);
            require([result[@"status"] isEqual:@"socket_unique"] && [result[@"pid"] intValue] == getpid(), [result description]);
            puts("UDP socket -> exact PID: PASS"); close(udp);

            close(client);
#ifdef YOYO_LOCAL_SOCKET_TEST
            require(!TZSurgeSessionIsCurrent(sourceCandidate, session), @"Closed socket must fail identity revalidation");
            puts("Source tuple live/stale/closed identity revalidation: PASS");
#endif
            result = post(vif);
            require([result[@"status"] isEqual:@"no_match"], [result description]);
            result = post(payload);
            require([result[@"status"] isEqual:@"no_match"] && result[@"pid"] == NSNull.null, [result description]);
            puts("Closed socket -> no_match: PASS"); close(listener);
            if (getenv("YOYO_EXPECT_ROUTE")) printf("PID launch zone %s -> %s: PASS\n", getenv("YOYO_EXPECT_ZONE"), getenv("YOYO_EXPECT_ROUTE"));
            return 0;
        } @catch (NSException *error) {
            fprintf(stderr, "%s\n", error.reason.UTF8String);
            if (child > 0) { kill(child, SIGTERM); waitpid(child, NULL, 0); }
            return 1;
        }
    }
}
