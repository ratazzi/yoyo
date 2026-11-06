#import "SurgeSocketPrototype.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <math.h>

static NSString *address(const struct in_sockinfo *socket, BOOL local) {
    char text[INET6_ADDRSTRLEN] = {};
    if (socket->insi_vflag & INI_IPV4) {
        const struct in_addr *value = local ? &socket->insi_laddr.ina_46.i46a_addr4 : &socket->insi_faddr.ina_46.i46a_addr4;
        inet_ntop(AF_INET, value, text, sizeof(text));
    } else {
        const struct in6_addr *value = local ? &socket->insi_laddr.ina_6 : &socket->insi_faddr.ina_6;
        inet_ntop(AF_INET6, value, text, sizeof(text));
    }
    return @(text);
}

NSDictionary *TZSurgeSocketCandidates(NSDictionary *request) {
    NSString *reported = [request[@"processPath"] isKindOfClass:NSString.class] ? request[@"processPath"] : nil;
    if (!reported.isAbsolutePath) return @{@"status": @"missing_process_path", @"pid": NSNull.null, @"candidates": @[]};
    NSString *expected = reported.stringByResolvingSymlinksInPath;
    int sourcePort = [request[@"sourcePort"] respondsToSelector:@selector(intValue)] ? [request[@"sourcePort"] intValue] : 0;
    int listenPort = [request[@"listenPort"] respondsToSelector:@selector(intValue)] ? [request[@"listenPort"] intValue] : 0;
    int destPort = [request[@"destPort"] respondsToSelector:@selector(intValue)] ? [request[@"destPort"] intValue] : 0;
    NSString *protocol = [request[@"protocol"] isKindOfClass:NSString.class] ? [request[@"protocol"] uppercaseString] : @"";
    BOOL udp = [@[@"UDP", @"QUIC", @"STUN"] containsObject:protocol];
    BOOL tcp = [@[@"TCP", @"HTTP", @"HTTPS"] containsObject:protocol];
    NSString *sourceIP = [request[@"sourceIP"] isKindOfClass:NSString.class] ? request[@"sourceIP"] : nil;
    NSMutableSet *destinations = [NSMutableSet new];
    NSString *hostname = [request[@"hostname"] isKindOfClass:NSString.class] ? request[@"hostname"] : @"";
    struct in6_addr scratch;
    if (inet_pton(AF_INET, hostname.UTF8String, &scratch) == 1 || inet_pton(AF_INET6, hostname.UTF8String, &scratch) == 1) [destinations addObject:hostname];
    NSDictionary *dns = [request[@"dnsResult"] isKindOfClass:NSDictionary.class] ? request[@"dnsResult"] : @{};
    for (NSString *key in @[@"v4Addresses", @"v6Addresses"]) if ([dns[key] isKindOfClass:NSArray.class])
        for (id value in dns[key]) if ([value isKindOfClass:NSString.class]) [destinations addObject:value];

    int capacity = proc_listallpids(NULL, 0) + 256;
    if (capacity < 256) capacity = 256;
    NSMutableData *storage = [NSMutableData dataWithLength:(NSUInteger)capacity * sizeof(pid_t)];
    int count = proc_listallpids(storage.mutableBytes, (int)storage.length);
    if (count < 0) return @{@"status": @"process_scan_failed", @"pid": NSNull.null, @"candidates": @[]};
    pid_t *pids = storage.mutableBytes;
    NSMutableArray *candidates = [NSMutableArray new], *verified = [NSMutableArray new];
    unsigned denied = 0, pathFailures = 0;
    for (int index = 0; index < count && index < capacity; index++) {
        pid_t pid = pids[index]; if (pid <= 0) continue;
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) { pathFailures++; continue; }
        if (![@(path).stringByResolvingSymlinksInPath isEqual:expected]) continue;
        struct proc_bsdinfo before, after;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, sizeof(before)) != sizeof(before)) { denied++; continue; }
        NSMutableArray *sockets = [NSMutableArray new]; BOOL strong = NO;
        if (sourcePort > 0 && sourcePort <= 65535) {
            int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
            if (bytes <= 0) { denied++; continue; }
            NSMutableData *fds = [NSMutableData dataWithLength:(NSUInteger)bytes + 64 * sizeof(struct proc_fdinfo)];
            bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds.mutableBytes, (int)fds.length);
            if (bytes < 0) { denied++; continue; }
            struct proc_fdinfo *entries = fds.mutableBytes;
            for (int fdIndex = 0; fdIndex < bytes / (int)sizeof(*entries); fdIndex++) {
                if (entries[fdIndex].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
                struct socket_fdinfo socket;
                if (proc_pidfdinfo(pid, entries[fdIndex].proc_fd, PROC_PIDFDSOCKETINFO, &socket, sizeof(socket)) != sizeof(socket)) { denied++; continue; }
                BOOL isTCP = socket.psi.soi_kind == SOCKINFO_TCP;
                if (!isTCP && socket.psi.soi_kind != SOCKINFO_IN) continue;
                if ((tcp && !isTCP) || (udp && socket.psi.soi_protocol != IPPROTO_UDP)) continue;
                const struct in_sockinfo *info = isTCP ? &socket.psi.soi_proto.pri_tcp.tcpsi_ini : &socket.psi.soi_proto.pri_in;
                if (ntohs((uint16_t)info->insi_lport) != sourcePort) continue;
                if (isTCP && socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN) continue;
                NSString *local = address(info, YES), *remote = address(info, NO);
                int remotePort = ntohs((uint16_t)info->insi_fport);
                BOOL sourceMatches = sourceIP.length && [local isEqual:sourceIP];
                if (sourceIP.length && !sourceMatches && ![@[@"0.0.0.0", @"::"] containsObject:local]) continue;
                BOOL proxy = listenPort > 0 && remotePort == listenPort && [@[@"127.0.0.1", @"::1"] containsObject:remote];
                BOOL direct = remotePort == destPort && [destinations containsObject:remote];
                BOOL exact = (tcp || udp) && sourceMatches && (proxy || direct);
                // VIF requests can omit both DNS results and a proxy listener. In that
                // case a unique source tuple still identifies the owner; never use
                // this fallback to override destination metadata that was supplied.
                BOOL sourceTuple = (tcp || udp) && sourceMatches && listenPort == 0 &&
                    destinations.count == 0 && destPort > 0 && remotePort == destPort;
                strong |= exact || sourceTuple;
                [sockets addObject:@{@"fd": @(entries[fdIndex].proc_fd), @"localIP": local, @"localPort": @(sourcePort),
                    @"remoteIP": remote, @"remotePort": @(remotePort), @"protocol": isTCP ? @"TCP" : @"UDP",
                    @"generation": @(info->insi_gencnt),
                    @"evidence": exact ? (proxy ? @"proxy_tuple" : @"destination_tuple") :
                        (sourceTuple ? @"source_tuple" : @"path_source_port")}];
            }
        }
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after) ||
            before.pbi_start_tvsec != after.pbi_start_tvsec || before.pbi_start_tvusec != after.pbi_start_tvusec ||
            proc_pidpath(pid, path, sizeof(path)) <= 0 || ![@(path).stringByResolvingSymlinksInPath isEqual:expected]) continue;
        if (!sourcePort || sockets.count) {
            NSDictionary *candidate = @{@"pid": @(pid), @"path": expected,
                @"started_at": @(before.pbi_start_tvsec + before.pbi_start_tvusec / 1e6), @"sockets": sockets};
            [candidates addObject:candidate]; if (strong) [verified addObject:candidate];
        }
    }
    // Missing inspection permission or multiple owners must never become a guessed PID.
    BOOL unique = verified.count == 1 && candidates.count == 1 && denied == 0;
    NSString *status = unique ? @"socket_unique" : (candidates.count > 1 ? @"ambiguous" :
        (denied ? @"inspection_limited" : (candidates.count ? (sourcePort ? @"socket_candidate" : @"path_only") : @"no_match")));
    return @{@"status": status, @"pid": unique ? verified[0][@"pid"] : NSNull.null,
        @"candidate_pid": candidates.count == 1 ? candidates[0][@"pid"] : NSNull.null,
        @"candidates": candidates, @"socket_inspection_failures": @(denied), @"unreadable_process_paths": @(pathFailures)};
}

BOOL TZSurgeSessionIsCurrent(NSDictionary *candidate, NSDictionary *session) {
    pid_t pid = [candidate[@"pid"] intValue];
    if (pid <= 1 || [session[@"pid"] intValue] != pid || ![session[@"pidversion"] isKindOfClass:NSNumber.class]) return NO;
    NSString *expected = [candidate[@"path"] isKindOfClass:NSString.class] ? candidate[@"path"] : nil;
    NSString *sessionPath = [session[@"path"] isKindOfClass:NSString.class] ? session[@"path"] : nil;
    if (!expected || ![expected.stringByResolvingSymlinksInPath isEqual:sessionPath.stringByResolvingSymlinksInPath]) return NO;
    audit_token_t audit = {};
    audit.val[5] = (uint32_t)pid; audit.val[7] = [session[@"pidversion"] unsignedIntValue];
    char path[PROC_PIDPATHINFO_MAXSIZE]; struct proc_bsdinfo process;
    // This public API asks the kernel to compare the exec generation as well as PID.
    if (proc_pidpath_audittoken(&audit, path, sizeof(path)) <= 0 || ![@(path).stringByResolvingSymlinksInPath isEqual:expected] ||
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, sizeof(process)) != sizeof(process)) return NO;
    double started = process.pbi_start_tvsec + process.pbi_start_tvusec / 1e6;
    if (fabs(started - [candidate[@"started_at"] doubleValue]) > 0.001 || fabs(started - [session[@"started_at"] doubleValue]) > 0.001) return NO;
    BOOL live = NO;
    for (NSDictionary *socket in candidate[@"sockets"]) {
        if (![@[@"proxy_tuple", @"destination_tuple", @"source_tuple"] containsObject:socket[@"evidence"]]) continue;
        struct socket_fdinfo current;
        if (proc_pidfdinfo(pid, [socket[@"fd"] intValue], PROC_PIDFDSOCKETINFO, &current, sizeof(current)) != sizeof(current)) continue;
        BOOL tcp = current.psi.soi_kind == SOCKINFO_TCP;
        if (!tcp && current.psi.soi_kind != SOCKINFO_IN) continue;
        const struct in_sockinfo *info = tcp ? &current.psi.soi_proto.pri_tcp.tcpsi_ini : &current.psi.soi_proto.pri_in;
        if (info->insi_gencnt == [socket[@"generation"] unsignedLongLongValue] &&
            ntohs((uint16_t)info->insi_lport) == [socket[@"localPort"] intValue] &&
            ntohs((uint16_t)info->insi_fport) == [socket[@"remotePort"] intValue] &&
            [address(info, YES) isEqual:socket[@"localIP"]] && [address(info, NO) isEqual:socket[@"remoteIP"]]) live = YES;
    }
    return live && proc_pidpath_audittoken(&audit, path, sizeof(path)) > 0 && [@(path).stringByResolvingSymlinksInPath isEqual:expected];
}
