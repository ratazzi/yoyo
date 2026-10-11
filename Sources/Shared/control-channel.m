#import "control-channel.h"
#import <Security/Security.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

BOOL tz_is_signed_ui(pid_t pid) {
    SecCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid: @(pid)};
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code);
    if (!status) status = SecRequirementCreateWithString(CFSTR("anchor apple generic and identifier \"dev.timezone.lab\" and certificate leaf[subject.OU] = \"74526N936A\""), kSecCSDefaultFlags, &requirement);
    if (!status) status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    return status == errSecSuccess;
}
static int connect_socket(NSString *path) {
    int socketFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socketFD < 0) return -1;
    struct timeval timeout = {.tv_sec = 1};
    setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int noSignal = 1; setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path)) >= sizeof(address.sun_path) ||
        connect(socketFD, (struct sockaddr *)&address, sizeof(address))) { close(socketFD); return -1; }
    return socketFD;
}
static NSDictionary *read_message(int socketFD) {
    NSMutableData *data = [NSMutableData new];
    char bytes[4096];
    while (data.length < 256 * 1024) {
        ssize_t count = read(socketFD, bytes, sizeof(bytes));
        if (count <= 0) return nil;
        char *newline = (char *)memchr(bytes, '\n', (size_t)count);
        [data appendBytes:bytes length:newline ? (NSUInteger)(newline - bytes) : (NSUInteger)count];
        if (newline) {
            id message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            return [message isKindOfClass:NSDictionary.class] ? message : nil;
        }
    }
    return nil;
}
static void send_message(int socketFD, NSDictionary *message) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t count = send(socketFD, (const char *)data.bytes + offset, data.length - offset, 0);
        if (count <= 0) break;
        offset += (size_t)count;
    }
}
NSDictionary *tz_control_request(NSString *path, NSDictionary *request, NSError **error) {
    int socketFD = connect_socket(path);
    if (socketFD < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return nil;
    }
    send_message(socketFD, request);
    NSDictionary *response = read_message(socketFD);
    close(socketFD);
    return response;
}
BOOL tz_control_listen(NSString *path, uid_t owner, TZControlHandler handler, NSError **error) {
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (server < 0 || strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path)) >= sizeof(address.sun_path)) return NO;
    unlink(address.sun_path);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) || listen(server, 128)) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        close(server); return NO;
    }
    chmod(address.sun_path, 0600); chown(address.sun_path, owner, (gid_t)-1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (;;) {
            int client = accept(server, NULL, NULL);
            if (client < 0) { if (errno == EINTR) continue; break; }
            int noSignal = 1;
            if (setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal))) { close(client); continue; }
            // Capture credentials before handing off: the peer may close while
            // the worker waits for CPU or the daemon's engine queue.
            uid_t uid; gid_t gid; pid_t pid = -1; socklen_t size = sizeof(pid);
            audit_token_t audit; socklen_t auditSize = sizeof(audit);
            if (getpeereid(client, &uid, &gid) || getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) ||
                getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, &audit, &auditSize) || auditSize != sizeof(audit)) {
                close(client); continue;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    struct timeval timeout = {.tv_sec = 1};
                    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
                    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
                    NSDictionary *request = read_message(client);
                    if (request) send_message(client, handler(request, pid, uid, audit) ?: @{});
                    close(client);
                }
            });
        }
        close(server);
    });
    return YES;
}
