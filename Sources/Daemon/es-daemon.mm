#import <Foundation/Foundation.h>
#import "program-policy.h"
#import "control-channel.h"
#include "startup-injector.hpp"
#include "timezone-policy.h"
#include <EndpointSecurity/EndpointSecurity.h>
#include <bsm/libbsm.h>
#include <mach/mach_time.h>
#include <libproc.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/stat.h>

// All policy, process and pending authorization state belongs to engineQueue.
@interface TZPending : NSObject
@property const es_message_t *message;
@property TZDecision *decision;
@property NSDictionary *parent;
@property NSString *identifier;
@property NSString *path;
@property double expires;
@end
@implementation TZPending
- (void)dealloc { if (_message) es_release_message(_message); }
@end

static es_client_t *client;
static dispatch_queue_t engineQueue;
static NSDictionary *configuration;
static TZProgramPolicy *policy;
static NSData *policyData;
static NSMutableDictionary *state, *records, *pending;
static NSMutableArray *recent;
static NSString *directory, *socketPath, *library, *uiPath;
static uid_t owner;
static NSUInteger sequence;
static BOOL filesSubscribed;
static double promptTimeout = 20;
static NSMutableDictionary *processDescriptors;
static NSMutableOrderedSet *descriptorOrder;
static NSMutableDictionary *processParentTokens;
static NSData *diagnosticConfig;
static NSString *diagnosticRun;
static double diagnosticUntil;
static int diagnosticFD = -1;

static NSString *token(es_string_token_t value) {
    return [[NSString alloc] initWithBytes:value.data length:value.length encoding:NSUTF8StringEncoding] ?: @"";
}
static NSString *key(audit_token_t value) {
    return [NSString stringWithFormat:@"%d:%u", audit_token_to_pid(value), value.val[7]];
}
static NSDictionary *remember_descriptor(NSDictionary *value) {
    NSString *identifier = value[@"id"];
    processDescriptors[identifier] = value;
    [descriptorOrder removeObject:identifier]; [descriptorOrder addObject:identifier];
    while (descriptorOrder.count > 4096) {
        [processParentTokens removeObjectForKey:descriptorOrder.firstObject];
        [processDescriptors removeObjectForKey:descriptorOrder.firstObject]; [descriptorOrder removeObjectAtIndex:0];
    }
    return value;
}
static NSDictionary *describe_process(const es_process_t *process, uint32_t version) {
    double started = version >= 3 ? process->start_time.tv_sec + process->start_time.tv_usec / 1e6 : 0;
    if (version >= 4) processParentTokens[key(process->audit_token)] = [NSData dataWithBytes:&process->parent_audit_token length:sizeof(audit_token_t)];
    return remember_descriptor(@{@"id": key(process->audit_token), @"pid": @(audit_token_to_pid(process->audit_token)),
        @"pidversion": @(process->audit_token.val[7]), @"path": token(process->executable->path), @"started_at": @(started),
        @"parent_id": version >= 4 ? key(process->parent_audit_token) : @"", @"parent_pid": @(process->ppid),
        @"uid": @(audit_token_to_euid(process->audit_token)), @"real_uid": @(audit_token_to_ruid(process->audit_token))});
}
static NSDictionary *describe_audit(audit_token_t audit) {
    NSString *identifier = key(audit);
    NSDictionary *known = processDescriptors[identifier];
    if (known) return remember_descriptor(known);
    pid_t pid = audit_token_to_pid(audit); if (pid <= 1) return nil;
    char path[PROC_PIDPATHINFO_MAXSIZE], verified[PROC_PIDPATHINFO_MAXSIZE]; struct proc_bsdinfo info;
    if (proc_pidpath_audittoken(&audit, path, sizeof(path)) <= 0) return nil;
    double started = 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) started = info.pbi_start_tvsec + info.pbi_start_tvusec / 1e6;
    // Verify the audit generation again after querying start time: never join by PID alone.
    if (proc_pidpath_audittoken(&audit, verified, sizeof(verified)) <= 0 || strcmp(path, verified)) return nil;
    return remember_descriptor(@{@"id": identifier, @"pid": @(pid), @"pidversion": @(audit.val[7]), @"path": @(path), @"started_at": @(started),
        @"uid": @(audit_token_to_euid(audit)), @"real_uid": @(audit_token_to_ruid(audit))});
}
static NSArray *describe_ancestors(NSDictionary *parent) {
    NSMutableArray *ancestors = [NSMutableArray new]; NSMutableSet *seen = [NSMutableSet new];
    NSDictionary *current = parent;
    while (current && ancestors.count < 12 && ![seen containsObject:current[@"id"]]) {
        [ancestors addObject:current]; [seen addObject:current[@"id"]];
        NSData *data = processParentTokens[current[@"id"]]; if (data.length != sizeof(audit_token_t)) break;
        audit_token_t token; [data getBytes:&token length:sizeof(token)]; current = describe_audit(token);
    }
    return ancestors;
}
static void reload_diagnostics(void) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"execution-diagnostics-config.json"]];
    if (data && ![data isEqual:diagnosticConfig]) {
        diagnosticConfig = data;
        if (diagnosticFD >= 0) close(diagnosticFD); diagnosticFD = -1;
        NSDictionary *value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSUUID *run = [value isKindOfClass:NSDictionary.class] && [value[@"run_id"] isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:value[@"run_id"]] : nil;
        double now = [NSDate date].timeIntervalSince1970;
        diagnosticUntil = run && [value[@"expires_at"] isKindOfClass:NSNumber.class] ? fmin([value[@"expires_at"] doubleValue], now + 600) : 0;
        diagnosticRun = run.UUIDString;
        if (diagnosticUntil > now) {
            NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"execution-diagnostics-%@.jsonl", diagnosticRun]];
            diagnosticFD = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
            if (diagnosticFD >= 0) fchown(diagnosticFD, owner, (gid_t)-1);
        }
    }
    if (diagnosticFD >= 0 && [NSDate date].timeIntervalSince1970 >= diagnosticUntil) { close(diagnosticFD); diagnosticFD = -1; }
    state[@"execution_diagnostics_active"] = @(diagnosticFD >= 0);
}
static void record_diagnostic(const es_message_t *message, NSDictionary *process, NSDictionary *parent, NSDictionary *responsible) {
    if (diagnosticFD < 0 || [NSDate date].timeIntervalSince1970 >= diagnosticUntil) return;
    NSDictionary *event = @{@"run_id": diagnosticRun, @"time": @([NSDate date].timeIntervalSince1970), @"type": @"exec",
        @"process": process, @"parent": parent ?: @{}, @"responsible": responsible ?: @{}, @"ancestors": describe_ancestors(parent),
        @"event_sequence": @(message->version >= 4 ? message->seq_num : 0),
        @"global_sequence": @(message->version >= 4 ? message->global_seq_num : 0)};
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] mutableCopy];
    [line appendBytes:"\n" length:1];
    if (write(diagnosticFD, line.bytes, line.length) != (ssize_t)line.length) {
        state[@"diagnostics_error"] = @"Execution diagnostic write failed"; close(diagnosticFD); diagnosticFD = -1;
    }
}
static double deadline_seconds(const es_message_t *message) {
    mach_timebase_info_data_t base; mach_timebase_info(&base);
    uint64_t now = mach_absolute_time();
    return message->deadline > now ? (double)(message->deadline - now) * base.numer / base.denom / 1e9 : 0;
}
static void write_json(NSString *name, id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}
static NSDictionary *public_record(NSDictionary *record) {
    TZSession *session = record[@"session"];
    return @{@"pid": record[@"pid"], @"pidversion": record[@"pidversion"], @"parent_pid": record[@"parent_pid"],
        @"path": record[@"path"], @"session": session.identifier, @"rule_id": session.ruleID,
        @"mode": session.mode, @"zone": [session.mode isEqual:@"fixed"] ? session.zone : @"", @"loaded": record[@"loaded"] ?: @NO,
        @"confirmation": ![session.mode isEqual:@"fixed"] ? @"not_requested" : ([record[@"loaded"] boolValue] ? @"confirmed" : @"unconfirmed"),
        @"logging": @([policy loggingEnabledForSession:session]),
        @"started_at": @([record[@"start_sec"] doubleValue] + [record[@"start_usec"] doubleValue] / 1e6)};
}
static void persist(void) {
    NSMutableArray *saved = [NSMutableArray new];
    for (NSDictionary *record in records.allValues) {
        NSMutableDictionary *item = [record mutableCopy]; TZSession *s = record[@"session"];
        item[@"session"] = @{@"id": s.identifier, @"rule": s.ruleID, @"mode": s.mode, @"zone": s.zone ?: @"",
            @"ancestors": s.ancestorRules.allObjects, @"log_rules": s.logRules.allObjects, @"baseline": s.baseline ?: @{}};
        [saved addObject:item];
    }
    write_json(@"active-sessions.json", saved);
    chmod([[directory stringByAppendingPathComponent:@"active-sessions.json"] fileSystemRepresentation], 0600);
}
static void publish(void) {
    state[@"updated_at"] = @([NSDate date].timeIntervalSince1970);
    state[@"es_enabled"] = @(policy.esEnabled); state[@"pending_count"] = @(pending.count);
    state[@"process_count"] = @(records.count);
    NSMutableArray *targets = [NSMutableArray new]; NSString *zone = @"";
    for (TZRule *rule in policy.rules) if (rule.enabled && [rule.mode isEqual:@"fixed"]) {
        [targets addObject:rule.pattern]; if (!zone.length) zone = rule.zone;
    }
    state[@"targets"] = targets; state[@"zone"] = zone;
    state[@"default_mode"] = policy.defaultMode; state[@"default_zone"] = policy.defaultZone;
    write_json(@"daemon-state.json", state);
}
static void log_event(NSDictionary *record, NSString *type, NSDictionary *details) {
    if (!record || ![policy loggingEnabledForSession:record[@"session"]]) return;
    NSMutableDictionary *event = [public_record(record) mutableCopy];
    event[@"type"] = type; event[@"time"] = @([NSDate date].timeIntervalSince1970); event[@"sequence"] = @(++sequence);
    [event addEntriesFromDictionary:details ?: @{}]; [recent addObject:event];
    if (recent.count > 5000) [recent removeObjectAtIndex:0];
    NSString *path = [directory stringByAppendingPathComponent:@"behavior.jsonl"];
    struct stat info;
    if (!lstat(path.fileSystemRepresentation, &info) && info.st_size > 4 * 1024 * 1024) {
        NSFileManager *fm = NSFileManager.defaultManager;
        for (int i = 3; i >= 1; i--) {
            NSString *from = [path stringByAppendingFormat:@".%d", i], *to = [path stringByAppendingFormat:@".%d", i + 1];
            [fm removeItemAtPath:to error:nil]; [fm moveItemAtPath:from toPath:to error:nil];
        }
        [fm moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
    }
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0600);
    if (fd >= 0) {
        fchown(fd, owner, (gid_t)-1);
        NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:event options:0 error:nil] mutableCopy];
        [line appendBytes:"\n" length:1]; write(fd, line.bytes, line.length); close(fd);
    }
}
static void flag_update(NSDictionary *record) {
    NSString *path = record[@"trace_control"]; if (!path) return;
    unsigned enabled = [policy loggingEnabledForSession:record[@"session"]] ? 1 : 0;
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_NOFOLLOW);
    if (fd >= 0) { pwrite(fd, &enabled, sizeof(enabled), 0); close(fd); }
}
static void cleanup_flag(NSString *path) {
    if (!path) return;
    for (NSDictionary *record in records.allValues) if ([record[@"trace_control"] isEqual:path]) return;
    unlink(path.fileSystemRepresentation);
}
static NSMutableDictionary *new_record(const es_process_t *process, TZSession *session) {
    return [@{@"pid": @(audit_token_to_pid(process->audit_token)), @"pidversion": @(process->audit_token.val[7]),
        @"uid": @(audit_token_to_euid(process->audit_token)), @"parent_pid": @(process->ppid),
        @"path": token(process->executable->path), @"session": session, @"loaded": @NO,
        @"start_sec": @(process->start_time.tv_sec), @"start_usec": @(process->start_time.tv_usec)} mutableCopy];
}
static NSMutableDictionary *record_for(const es_process_t *process) {
    NSMutableDictionary *record = records[key(process->audit_token)]; if (record) return record;
    // Reconcile audit generation after daemon restart using kernel start time and executable.
    for (NSMutableDictionary *candidate in records.allValues) {
        if ([candidate[@"pid"] intValue] == audit_token_to_pid(process->audit_token) &&
            [candidate[@"start_sec"] longLongValue] == process->start_time.tv_sec &&
            [candidate[@"start_usec"] intValue] == process->start_time.tv_usec &&
            [candidate[@"path"] isEqual:token(process->executable->path)]) return candidate;
    }
    return nil;
}
static void restore(void) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"active-sessions.json"]];
    id saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![saved isKindOfClass:NSArray.class]) return;
    for (NSDictionary *item in saved) {
        struct proc_bsdinfo info; char path[PROC_PIDPATHINFO_MAXSIZE]; pid_t pid = [item[@"pid"] intValue];
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
            info.pbi_start_tvsec != [item[@"start_sec"] unsignedLongLongValue] ||
            info.pbi_start_tvusec != [item[@"start_usec"] unsignedLongLongValue] ||
            proc_pidpath(pid, path, sizeof(path)) <= 0 || ![item[@"path"] isEqual:@(path)]) continue;
        NSDictionary *value = item[@"session"]; TZSession *s = [TZSession new];
        s.identifier = value[@"id"]; s.ruleID = value[@"rule"]; s.mode = value[@"mode"]; s.zone = value[@"zone"];
        s.ancestorRules = [NSSet setWithArray:value[@"ancestors"] ?: @[]]; s.logRules = [NSSet setWithArray:value[@"log_rules"] ?: @[]];
        s.baseline = value[@"baseline"] ?: @{};
        if (!s.identifier || !s.ruleID || !s.mode) continue;
        NSMutableDictionary *record = [item mutableCopy]; record[@"session"] = s;
        records[[NSString stringWithFormat:@"%d:%@", pid, item[@"pidversion"]]] = record;
    }
}
static void reload_policy(void) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"policy.json"]];
    if (!data || [data isEqual:policyData]) return;
    NSError *error; NSDictionary *value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    TZProgramPolicy *updated = value ? [TZProgramPolicy policyWithDictionary:value error:&error] : nil;
    if (!updated) { state[@"policy_error"] = error.localizedDescription ?: @"Invalid policy"; return; }
    policy = updated; policyData = data; [state removeObjectForKey:@"policy_error"];
    promptTimeout = value[@"prompt_timeout_seconds"] ? fmax(1, fmin(30, [value[@"prompt_timeout_seconds"] doubleValue])) : 20;
    for (NSDictionary *record in records.allValues) flag_update(record);
    BOOL enabled = NO;
    for (TZRule *rule in policy.rules) enabled |= rule.enabled && rule.logging;
    es_event_type_t events[] = {ES_EVENT_TYPE_NOTIFY_OPEN, ES_EVENT_TYPE_NOTIFY_CLOSE, ES_EVENT_TYPE_NOTIFY_WRITE,
        ES_EVENT_TYPE_NOTIFY_READLINK, ES_EVENT_TYPE_NOTIFY_MMAP, ES_EVENT_TYPE_NOTIFY_RENAME,
        ES_EVENT_TYPE_NOTIFY_CREATE, ES_EVENT_TYPE_NOTIFY_UNLINK};
    if (client && enabled != filesSubscribed) {
        es_return_t result = enabled ? es_subscribe(client, events, sizeof(events) / sizeof(*events)) : es_unsubscribe(client, events, sizeof(events) / sizeof(*events));
        if (result == ES_RETURN_SUCCESS) filesSubscribed = enabled;
        else state[@"logging_error"] = @"Could not change file event subscriptions";
    }
}
static NSDictionary *parent_record(const es_message_t *message) {
    NSDictionary *record = record_for(message->process); if (record) return record;
    const es_process_t *target = message->event.exec.target;
    if (message->version >= 4) {
        record = records[key(target->parent_audit_token)]; if (record) return record;
        record = records[key(target->responsible_audit_token)];
        if (record) {
            TZSession *session = record[@"session"];
            NSString *path = token(target->executable->path);
            for (TZRule *rule in policy.rules) if ([rule.kind isEqual:@"app"] &&
                [session.ancestorRules containsObject:rule.identifier] && [path hasPrefix:[rule.pattern stringByAppendingString:@"/"]]) return record;
        }
    }
    return nil;
}
static NSDictionary *baseline(const es_message_t *message) {
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (uint32_t i = 0; i < es_exec_env_count(&message->event.exec); i++) {
        NSString *entry = token(es_exec_env(&message->event.exec, i));
        if ([entry hasPrefix:@"TZ="]) values[@"TZ"] = [entry substringFromIndex:3];
        if ([entry hasPrefix:@"TZFILE="]) values[@"TZFILE"] = [entry substringFromIndex:7];
    }
    return values;
}
static BOOL inherited_insertion(const es_message_t *message) {
    for (uint32_t i = 0; i < es_exec_env_count(&message->event.exec); i++) {
        NSString *entry = token(es_exec_env(&message->event.exec, i));
        if ([entry hasPrefix:@"TIMEZONE_LAB_SESSION="]) return YES;
        if ([entry hasPrefix:@"DYLD_INSERT_LIBRARIES="] && [[[entry substringFromIndex:22] componentsSeparatedByString:@":"] containsObject:library]) return YES;
    }
    return NO;
}
static void complete(const es_message_t *message, TZDecision *decision, NSDictionary *parent, BOOL cancel) {
    TZSession *session = decision.session; const es_process_t *target = message->event.exec.target;
    NSMutableDictionary *record = session ? new_record(target, session) : nil;
    BOOL allowed = !cancel; NSString *detail = cancel ? @"Launch cancelled or prompt expired" : @"Default: no injection";
    NSString *tracePath = nil;
    if (allowed && session) {
        if (!session.baseline) session.baseline = baseline(message);
        BOOL fixed = [session.mode isEqual:@"fixed"];
        if (fixed || inherited_insertion(message)) {
            try {
                if (deadline_seconds(message) < 0.25) throw std::runtime_error("insufficient AUTH_EXEC deadline remaining");
                StartupTimezone setting;
                setting.zone = fixed ? session.zone.UTF8String : "";
                TZSession *previous = parent[@"session"]; setting.previous_zone = previous.zone.UTF8String ?: "";
                for (NSString *name in session.baseline) setting.baseline[name.UTF8String] = [session.baseline[name] UTF8String];
                if (fixed) {
                    tracePath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"trace-%@.flag", NSUUID.UUID.UUIDString]];
                    unsigned flag = [policy loggingEnabledForSession:session] ? 1 : 0;
                    int fd = open(tracePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
                    if (fd < 0 || write(fd, &flag, sizeof(flag)) != sizeof(flag)) { if (fd >= 0) close(fd); throw std::runtime_error("cannot create trace control"); }
                    close(fd); record[@"trace_control"] = tracePath;
                    setting.extra["TIMEZONE_LAB_SESSION"] = session.identifier.UTF8String;
                    setting.extra["TIMEZONE_LAB_LOG_SOCKET"] = socketPath.UTF8String;
                    setting.extra["TIMEZONE_LAB_TRACE_CONTROL"] = tracePath.UTF8String;
                }
                configure_startup_environment(audit_token_to_pid(target->audit_token), library.UTF8String, setting);
                detail = fixed ? @"Startup environment prepared; awaiting hooks_loaded" : @"Inherited injection removed";
            } catch (const std::exception &error) { allowed = NO; detail = @(error.what()); }
        }
    }
    if (allowed && record) records[key(target->audit_token)] = record;
    es_respond_result_t response = es_respond_auth_result(client, message, allowed ? ES_AUTH_RESULT_ALLOW : ES_AUTH_RESULT_DENY, false);
    if (response != ES_RESPOND_RESULT_SUCCESS) { allowed = NO; [records removeObjectForKey:key(target->audit_token)]; }
    if (!allowed) cleanup_flag(tracePath);
    if (session) {
        state[@"last_event"] = @{@"pid": @(audit_token_to_pid(target->audit_token)), @"path": token(target->executable->path),
            @"status": allowed ? ([session.mode isEqual:@"fixed"] ? @"prepared" : @"default") : @"denied",
            @"detail": detail, @"auth_response": @(response), @"time": @([NSDate date].timeIntervalSince1970)};
        log_event(record, allowed ? @"launch" : @"launch_denied", @{@"detail": detail}); persist(); publish();
    }
}
static void resolve(NSString *identifier, NSString *mode, NSString *zone) {
    TZPending *request = pending[identifier]; if (!request) return;
    BOOL cancel = [mode isEqual:@"cancel"] || [NSDate date].timeIntervalSince1970 >= request.expires;
    if (!cancel) { request.decision.session.mode = mode; request.decision.session.zone = zone ?: @""; }
    [pending removeObjectForKey:identifier]; complete(request.message, request.decision, request.parent, cancel);
}
static void process_message(const es_message_t *message) {
    // Broad user rules must never turn the logger's own file writes into more logs.
    if (message->event_type != ES_EVENT_TYPE_AUTH_EXEC && audit_token_to_pid(message->process->audit_token) == getpid()) return;
    if (message->event_type == ES_EVENT_TYPE_AUTH_EXEC) {
        NSString *path = token(message->event.exec.target->executable->path);
        if ([path isEqual:uiPath] || [path isEqual:NSBundle.mainBundle.executablePath]) {
            es_respond_auth_result(client, message, ES_AUTH_RESULT_ALLOW, false); return;
        }
        NSDictionary *parent = parent_record(message);
        NSString *invoked = message->version >= 7 ? token(message->event.exec.dyld_exec_path) : nil;
        NSString *script = message->version >= 2 && message->event.exec.script ? token(message->event.exec.script->path) : nil;
        TZDecision *decision = [policy decisionForPath:path invokedPath:invoked script:script parent:parent[@"session"]];
        if (!decision.ask) { complete(message, decision, parent, NO); return; }
        TZPending *request = [TZPending new]; es_retain_message(message); request.message = message;
        request.decision = decision; request.parent = parent; request.path = path; request.identifier = NSUUID.UUID.UUIDString;
        double timeout = fmin(promptTimeout, deadline_seconds(message) - 0.5);
        if (timeout <= 0) { complete(message, decision, parent, YES); return; }
        request.expires = [NSDate date].timeIntervalSince1970 + timeout; pending[request.identifier] = request;
        NSString *identifier = request.identifier;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), engineQueue, ^{ resolve(identifier, @"cancel", nil); });
        publish(); return;
    }
    NSMutableDictionary *record = record_for(message->process);
    if (message->event_type == ES_EVENT_TYPE_NOTIFY_FORK) {
        if (diagnosticFD >= 0) {
            describe_process(message->process, message->version);
            describe_process(message->event.fork.child, message->version);
        }
        if (record) {
            const es_process_t *child = message->event.fork.child;
            NSMutableDictionary *copy = new_record(child, [record[@"session"] copy]); copy[@"loaded"] = record[@"loaded"];
            if (record[@"trace_control"]) copy[@"trace_control"] = record[@"trace_control"];
            records[key(child->audit_token)] = copy; log_event(copy, @"fork", nil); persist();
        }
        return;
    }
    if (message->event_type == ES_EVENT_TYPE_NOTIFY_EXEC) {
        const es_process_t *target = message->event.exec.target;
        NSString *executable = token(target->executable->path);
        if (diagnosticFD >= 0 && (audit_token_to_ruid(target->audit_token) == owner || audit_token_to_euid(target->audit_token) == owner) &&
            ![executable isEqual:uiPath] && ![executable isEqual:NSBundle.mainBundle.executablePath]) {
            describe_process(message->process, message->version);
            NSDictionary *process = describe_process(target, message->version);
            NSDictionary *parent = message->version >= 4 ? describe_audit(target->parent_audit_token) : nil;
            NSDictionary *responsible = message->version >= 4 ? describe_audit(target->responsible_audit_token) : nil;
            record_diagnostic(message, process, parent, responsible);
        }
        record = record_for(message->event.exec.target);
        pid_t pid = audit_token_to_pid(message->event.exec.target->audit_token);
        NSString *current = key(message->event.exec.target->audit_token);
        for (NSString *old in records.allKeys) if (![old isEqual:current] && [records[old][@"pid"] intValue] == pid) {
            NSString *flag = records[old][@"trace_control"]; [records removeObjectForKey:old]; cleanup_flag(flag);
        }
        if (record) { log_event(record, @"exec", nil); persist(); } return;
    }
    if (message->event_type == ES_EVENT_TYPE_NOTIFY_EXIT) {
        if (!record) return;
        log_event(record, @"exit", @{@"status": @(message->event.exit.stat)});
        NSString *flag = record[@"trace_control"]; [records removeObjectForKey:key(message->process->audit_token)]; cleanup_flag(flag); persist(); return;
    }
    if (!record) {
        TZDecision *decision = [policy decisionForPath:token(message->process->executable->path) invokedPath:nil script:nil parent:nil];
        if (![policy loggingEnabledForSession:decision.session]) return;
        // Observe an existing process without changing its timezone or asking retroactively.
        decision.session.mode = @"default"; decision.session.zone = @""; decision.session.ancestorRules = [NSSet set];
        record = new_record(message->process, decision.session); records[key(message->process->audit_token)] = record;
    }
    NSString *operation = nil, *path = nil, *destination = nil;
    switch (message->event_type) {
        case ES_EVENT_TYPE_NOTIFY_OPEN: operation = @"open"; path = token(message->event.open.file->path); break;
        case ES_EVENT_TYPE_NOTIFY_CLOSE: operation = @"close"; path = token(message->event.close.target->path); break;
        case ES_EVENT_TYPE_NOTIFY_WRITE: operation = @"write"; path = token(message->event.write.target->path); break;
        case ES_EVENT_TYPE_NOTIFY_READLINK: operation = @"readlink"; path = token(message->event.readlink.source->path); break;
        case ES_EVENT_TYPE_NOTIFY_MMAP: operation = @"mmap"; path = token(message->event.mmap.source->path); break;
        case ES_EVENT_TYPE_NOTIFY_UNLINK: operation = @"unlink"; path = token(message->event.unlink.target->path); break;
        case ES_EVENT_TYPE_NOTIFY_RENAME:
            operation = @"rename"; path = token(message->event.rename.source->path);
            destination = message->event.rename.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE ? token(message->event.rename.destination.existing_file->path) :
                [token(message->event.rename.destination.new_path.dir->path) stringByAppendingPathComponent:token(message->event.rename.destination.new_path.filename)]; break;
        case ES_EVENT_TYPE_NOTIFY_CREATE:
            operation = @"create"; path = message->event.create.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE ? token(message->event.create.destination.existing_file->path) :
                [token(message->event.create.destination.new_path.dir->path) stringByAppendingPathComponent:token(message->event.create.destination.new_path.filename)]; break;
        default: return;
    }
    log_event(record, @"file", @{@"operation": operation, @"file": path ?: @"", @"destination": destination ?: @""});
}
static NSDictionary *control(NSDictionary *request, pid_t pid, uid_t uid, audit_token_t audit) {
    NSString *command = request[@"command"];
    if ([command isEqual:@"trace"]) {
        // A fork record and its exec replacement can temporarily share PID/session.
        // A constructor acknowledgement belongs only to the peer's exec generation.
        NSMutableDictionary *record = records[key(audit)];
        if (record) {
            TZSession *session = record[@"session"];
            if ([record[@"pid"] intValue] != pid || [record[@"uid"] unsignedIntValue] != uid || ![session.identifier isEqual:request[@"session"]]) return @{@"error": @"Unknown process session"};
            NSString *operation = request[@"operation"];
            if (![operation isKindOfClass:NSString.class] || operation.length > 80) return @{@"error": @"Invalid operation"};
            if ([operation isEqual:@"hooks_loaded"]) {
                NSString *receipt = request[@"receipt"];
                if (receipt && (![receipt isKindOfClass:NSString.class] || receipt.length != 32 ||
                    [receipt rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound))
                    return @{@"error": @"Invalid receipt"};
                // Replays from this same audit generation are acknowledgements,
                // not new launches or duplicate log events.
                if (![record[@"loaded"] boolValue]) {
                    record[@"loaded"] = @YES; persist(); publish();
                    log_event(record, @"timezone", @{@"operation": operation, @"zone": session.zone ?: @""});
                }
                return receipt ? @{@"ack": receipt} : @{@"ok": @YES};
            }
            log_event(record, @"timezone", @{@"operation": operation, @"zone": session.zone ?: @""});
            return @{@"ok": @YES};
        }
        return @{@"error": @"Unknown process session"};
    }
    if (uid != owner || !tz_is_signed_ui(pid)) return @{@"error": @"Signed owner UI required"};
    if ([command isEqual:@"process"]) {
        pid_t target = [request[@"pid"] intValue];
        struct proc_bsdinfo info; char path[PROC_PIDPATHINFO_MAXSIZE];
        if (target > 1 && proc_pidinfo(target, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
            proc_pidpath(target, path, sizeof(path)) > 0) {
            for (NSDictionary *record in records.allValues) {
                if ([record[@"pid"] intValue] == target && [record[@"start_sec"] unsignedLongLongValue] == info.pbi_start_tvsec &&
                    [record[@"start_usec"] unsignedLongLongValue] == info.pbi_start_tvusec && [record[@"path"] isEqual:@(path)]) {
                    return @{@"process": public_record(record)};
                }
            }
        }
        return @{@"process": NSNull.null};
    }
    if ([command isEqual:@"answer"]) {
        NSString *mode = request[@"mode"], *zone = canonical_timezone_name(request[@"zone"]);
        if (![@[@"fixed", @"default", @"cancel"] containsObject:mode] || ([mode isEqual:@"fixed"] && !zone)) return @{@"error": @"Invalid answer"};
        if (!pending[request[@"id"] ?: @""]) return @{@"error": @"Prompt expired"};
        resolve(request[@"id"], mode, zone); return @{@"ok": @YES};
    }
    if ([command isEqual:@"reload"]) { reload_policy(); publish(); return @{@"ok": @YES}; }
    if (![command isEqual:@"poll"]) return @{@"error": @"Unknown command"};
    NSMutableArray *prompts = [NSMutableArray new], *processes = [NSMutableArray new], *events = [NSMutableArray new];
    for (TZPending *p in pending.allValues) [prompts addObject:@{@"id": p.identifier, @"path": p.path,
        @"name": p.decision.rule.name, @"zone": p.decision.session.zone, @"expires_at": @(p.expires),
        @"parent_path": p.parent[@"path"] ?: @"", @"parent_pid": p.parent[@"pid"] ?: @0}];
    if (![request[@"include_processes"] isEqual:@NO]) for (NSDictionary *record in records.allValues) {
        if (processes.count == 200) break; [processes addObject:public_record(record)];
    }
    for (NSDictionary *event in [request[@"include_events"] isEqual:@NO] ? @[] : recent) if ([event[@"sequence"] unsignedIntegerValue] > [request[@"after"] unsignedIntegerValue]) {
        [events addObject:event]; if (events.count == 100) break;
    }
    return @{@"state": [state copy], @"policy": policy.dictionary, @"prompts": prompts, @"processes": processes, @"events": events};
}
static void test_startup_confirmation(void) {
    char temporary[] = "/private/tmp/timezone-confirm-XXXXXX";
    if (!mkdtemp(temporary)) throw std::runtime_error("cannot create confirmation test directory");
    directory = @(temporary); owner = getuid();
    state = [NSMutableDictionary new]; records = [NSMutableDictionary new]; pending = [NSMutableDictionary new]; recent = [NSMutableArray new];
    policy = [TZProgramPolicy policyWithDictionary:@{@"version": @2, @"es_enabled": @YES, @"rules": @[
        @{@"id": @"test", @"kind": @"cli", @"pattern": @"/test", @"mode": @"fixed", @"zone": @"Asia/Tokyo", @"enabled": @YES, @"logging": @YES}
    ]} error:nil];
    TZSession *session = [policy decisionForPath:@"/test" invokedPath:nil script:nil parent:nil].session;
    audit_token_t audit = {}; audit.val[5] = (uint32_t)getpid(); audit.val[7] = 2;
    NSMutableDictionary *record = [@{@"pid": @(getpid()), @"pidversion": @2, @"uid": @(owner), @"parent_pid": @1,
        @"path": @"/test", @"session": session, @"loaded": @NO, @"start_sec": @1, @"start_usec": @0} mutableCopy];
    audit_token_t previous = audit; previous.val[7] = 1;
    NSMutableDictionary *old = [record mutableCopy]; old[@"pidversion"] = @1;
    records[key(previous)] = old; records[key(audit)] = record;
    NSString *receipt = @"0123456789abcdef0123456789abcdef";
    NSMutableDictionary *request = [@{@"command": @"trace", @"operation": @"hooks_loaded", @"session": session.identifier, @"receipt": receipt} mutableCopy];
    BOOL valid = policy && session && [public_record(record)[@"confirmation"] isEqual:@"unconfirmed"];
    request[@"receipt"] = @"invalid";
    valid &= control(request, getpid(), owner, audit)[@"error"] != nil && ![record[@"loaded"] boolValue];
    request[@"receipt"] = receipt;
    valid &= control(request, getpid(), owner + 1, audit)[@"error"] != nil;
    audit_token_t unknown = audit; unknown.val[7] = 3;
    valid &= control(request, getpid(), owner, unknown)[@"error"] != nil;
    request[@"session"] = @"wrong-session";
    valid &= control(request, getpid(), owner, audit)[@"error"] != nil;
    request[@"session"] = session.identifier;
    valid &= [control(request, getpid(), owner, audit)[@"ack"] isEqual:receipt];
    valid &= [record[@"loaded"] boolValue] && ![old[@"loaded"] boolValue] && [public_record(record)[@"confirmation"] isEqual:@"confirmed"];
    NSUInteger logged = recent.count;
    for (int attempt = 0; attempt < 5; attempt++) valid &= [control(request, getpid(), owner, audit)[@"ack"] isEqual:receipt];
    valid &= logged == 1 && recent.count == logged;
    NSArray *saved = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"active-sessions.json"]] options:0 error:nil];
    valid &= saved.count == 2;
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    if (!valid) throw std::runtime_error("startup confirmation validation failed");
    puts("Startup confirmation: exact audit generation, receipt validation, idempotence and unknown state: PASS");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--self-test")) {
            try { test_startup_stack_rewrite(); puts("startup stack preservation: PASS"); test_startup_confirmation(); return 0; }
            catch (const std::exception &e) { fprintf(stderr, "%s\n", e.what()); return 1; }
        }
        if (argc != 2) return 2;
        NSString *path = @(argv[1]);
        if ([path isEqual:@"--bundle-config"]) {
            NSString *bundle = NSBundle.mainBundle.bundlePath;
            for (int i = 0; i < 4; i++) bundle = bundle.stringByDeletingLastPathComponent;
            path = [bundle stringByAppendingPathComponent:@"Contents/Resources/lab-config.json"];
        }
        NSData *data = [NSData dataWithContentsOfFile:path];
        configuration = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![configuration isKindOfClass:NSDictionary.class]) return 2;
        NSMutableDictionary *resolved = [configuration mutableCopy];
        NSString *bundle = path; for (int i = 0; i < 3; i++) bundle = bundle.stringByDeletingLastPathComponent;
        library = configuration[@"library"]; if (!library.isAbsolutePath) library = [bundle stringByAppendingPathComponent:library];
        uiPath = [bundle stringByAppendingPathComponent:@"Contents/MacOS/TimezoneLab"];
        NSMutableArray *targets = [NSMutableArray new];
        for (NSString *target in configuration[@"targets"]) [targets addObject:target.isAbsolutePath ? target : [bundle stringByAppendingPathComponent:target]];
        resolved[@"targets"] = targets; configuration = resolved;
        directory = configuration[@"state_directory"]; if (!directory.isAbsolutePath || !library.isAbsolutePath) return 2;
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        struct stat info; if (stat(directory.fileSystemRepresentation, &info)) return 2; owner = info.st_uid;
        socketPath = [directory stringByAppendingPathComponent:@"control.sock"];
        engineQueue = dispatch_queue_create("dev.timezone.lab.engine", DISPATCH_QUEUE_SERIAL);
        records = [NSMutableDictionary new]; pending = [NSMutableDictionary new]; recent = [NSMutableArray new];
        processDescriptors = [NSMutableDictionary new]; descriptorOrder = [NSMutableOrderedSet new]; processParentTokens = [NSMutableDictionary new];
        state = [@{@"pid": @(getpid()), @"status": @"starting", @"injection_method": @"AUTH_EXEC + startup environment rewrite"} mutableCopy];
        policy = [TZProgramPolicy policyWithDictionary:configuration error:nil]; if (!policy) return 2;
        restore(); reload_policy(); publish();
        NSError *error;
        if (!tz_control_listen(socketPath, owner, ^NSDictionary *(NSDictionary *request, pid_t pid, uid_t uid, audit_token_t audit) {
            __block NSDictionary *reply;
            dispatch_sync(engineQueue, ^{ reply = control(request, pid, uid, audit); }); return reply;
        }, &error)) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        es_new_client_result_t result = es_new_client(&client, ^(es_client_t *es, const es_message_t *message) {
            es_retain_message(message);
            dispatch_async(engineQueue, ^{ @autoreleasepool { process_message(message); es_release_message(message); } });
        });
        if (result != ES_NEW_CLIENT_RESULT_SUCCESS) {
            state[@"status"] = @"error"; state[@"error"] = [NSString stringWithFormat:@"es_new_client=%d (check signature, root and Full Disk Access)", result];
            publish(); return 1;
        }
        es_event_type_t events[] = {ES_EVENT_TYPE_AUTH_EXEC, ES_EVENT_TYPE_NOTIFY_EXEC, ES_EVENT_TYPE_NOTIFY_FORK, ES_EVENT_TYPE_NOTIFY_EXIT};
        if (es_subscribe(client, events, 4) != ES_RETURN_SUCCESS) { es_delete_client(client); return 1; }
        dispatch_sync(engineQueue, ^{ state[@"status"] = @"listening"; policyData = nil; reload_policy(); publish(); });
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, engineQueue);
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { reload_policy(); reload_diagnostics(); publish(); } }); dispatch_resume(timer);
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, engineQueue);
        dispatch_source_set_event_handler(term, ^{
            es_unsubscribe_all(client);
            for (NSString *identifier in pending.allKeys) resolve(identifier, @"cancel", nil);
            persist(); if (diagnosticFD >= 0) close(diagnosticFD);
            es_delete_client(client); state[@"status"] = @"stopped"; publish(); unlink(socketPath.fileSystemRepresentation); exit(0);
        }); dispatch_resume(term); dispatch_main();
    }
}
