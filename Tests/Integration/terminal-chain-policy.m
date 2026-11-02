#import <Foundation/Foundation.h>

static id read_document(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    return [path.pathExtension isEqual:@"plist"] ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:nil] : [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
}
static BOOL write_document(NSString *path, id value) {
    NSData *data = [path.pathExtension isEqual:@"plist"] ? [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] : [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:nil];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) return 2;
        NSString *command = @(argv[1]), *path = @(argv[2]);
        if ([command isEqual:@"offset"]) {
            NSTimeZone *zone = [NSTimeZone timeZoneWithName:path]; if (!zone) return 2;
            NSInteger seconds = [zone secondsFromGMTForDate:NSDate.date], absolute = labs(seconds);
            printf("%c%02ld%02ld\n", seconds < 0 ? '-' : '+', (long)(absolute / 3600), (long)(absolute % 3600 / 60)); return 0;
        }
        id value = read_document(path); if (![value isKindOfClass:NSDictionary.class]) return 2;
        if ([command isEqual:@"date-zone"]) {
            for (NSDictionary *rule in value[@"rules"]) if ([rule[@"enabled"] boolValue] && [rule[@"mode"] isEqual:@"fixed"]) {
                puts([rule[@"zone"] UTF8String]); return 0;
            }
            return 1;
        }
        if ([command isEqual:@"field"] && argc == 4) {
            NSDictionary *record = value[@"process"]; if (![record isKindOfClass:NSDictionary.class]) return 1;
            id field = record[@(argv[3])];
            if (!field || field == NSNull.null) return 1;
            puts([[field description] UTF8String]); return 0;
        }
        if ([command isEqual:@"verify"] && argc == 5) {
            NSDictionary *record = value[@"process"];
            if (![record isKindOfClass:NSDictionary.class]) return 1;
            BOOL valid = [record isKindOfClass:NSDictionary.class] && [record[@"loaded"] boolValue] &&
                [record[@"confirmation"] isEqual:@"confirmed"] && [record[@"mode"] isEqual:@"fixed"] &&
                [record[@"zone"] isEqual:@(argv[3])] && [record[@"session"] isEqual:@(argv[4])];
            printf("pid=%d hooks_loaded=%d confirmation=%s zone=%s session=%s: %s\n", [record[@"pid"] intValue], [record[@"loaded"] boolValue],
                [record[@"confirmation"] UTF8String] ?: "unknown", [record[@"zone"] UTF8String] ?: "", [record[@"session"] UTF8String] ?: "", valid ? "PASS" : "FAIL");
            return valid ? 0 : 1;
        }
        if (argc != 4 || ![value[@"rules"] isKindOfClass:NSArray.class]) return 2;
        NSString *backupPath = @(argv[3]);
        if ([command isEqual:@"backup"]) {
            NSMutableArray *rules = [NSMutableArray new];
            for (NSDictionary *rule in value[@"rules"]) if ([rule[@"kind"] isEqual:@"cli"] && [rule[@"pattern"] isEqual:@"/bin/date"]) [rules addObject:rule];
            return write_document(backupPath, @{@"token": NSUUID.UUID.UUIDString, @"rules": rules}) ? 0 : 2;
        }
        NSDictionary *backup = read_document(backupPath); if (!backup[@"token"]) return 2;
        BOOL changed = NO;
        if ([command isEqual:@"disable"]) {
            for (NSMutableDictionary *rule in value[@"rules"]) {
                if ([rule[@"kind"] isEqual:@"cli"] && [rule[@"pattern"] isEqual:@"/bin/date"] && [rule[@"enabled"] boolValue]) {
                    rule[@"enabled"] = @NO; rule[@"_chain_test_token"] = backup[@"token"];
                    changed = YES;
                }
            }
        } else if ([command isEqual:@"restore"]) {
            for (NSMutableDictionary *rule in value[@"rules"]) {
                if (![rule[@"_chain_test_token"] isEqual:backup[@"token"]]) continue;
                changed = YES;
                for (NSDictionary *original in backup[@"rules"]) {
                    if ([rule[@"id"] isEqual:original[@"id"]] && [rule[@"pattern"] isEqual:original[@"pattern"]] &&
                        [rule[@"mode"] isEqual:original[@"mode"]] && [rule[@"zone"] isEqual:original[@"zone"]]) rule[@"enabled"] = original[@"enabled"];
                }
                [rule removeObjectForKey:@"_chain_test_token"];
            }
        } else return 2;
        return !changed || write_document(path, value) ? 0 : 2;
    }
}
