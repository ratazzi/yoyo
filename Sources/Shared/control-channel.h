#pragma once
#import <Foundation/Foundation.h>
#include <sys/types.h>
#include <mach/message.h>

typedef NSDictionary *(^TZControlHandler)(NSDictionary *, pid_t, uid_t, audit_token_t);
#ifdef __cplusplus
extern "C" {
#endif
// The daemon validates authorization; peer identity and exec generation come from the kernel.
BOOL tz_control_listen(NSString *path, uid_t owner, TZControlHandler handler, NSError **error);
NSDictionary *tz_control_request(NSString *path, NSDictionary *request, NSError **error);
BOOL tz_is_signed_ui(pid_t pid);
#ifdef __cplusplus
}
#endif
