#pragma once
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT BOOL TZWritePrivateData(NSData *data, NSString *path, NSError **error);

@interface TZPolicyFile : NSObject
+ (NSDictionary *)readFromDirectory:(NSString *)directory migrateLegacy:(BOOL)migrate error:(NSError **)error;
+ (BOOL)write:(NSDictionary *)value toDirectory:(NSString *)directory error:(NSError **)error;
@end

@interface TZRule : NSObject
@property(copy) NSString *identifier;
@property(copy) NSString *name;
@property(copy) NSString *kind; // app | cli
@property(copy) NSString *pattern;
@property(copy) NSString *mode; // default | fixed | ask
@property(copy) NSString *zone;
@property BOOL enabled;
@property BOOL logging;
@property(copy) NSDictionary<NSString *, NSString *> *environment;
- (NSDictionary *)dictionary;
@end

@interface TZSession : NSObject <NSCopying>
@property(copy) NSString *identifier;
@property(copy) NSString *ruleID;
@property(copy) NSString *mode; // resolved default | fixed
@property(copy) NSString *zone;
@property BOOL logging;
@property(copy) NSSet<NSString *> *ancestorRules;
@property(copy) NSSet<NSString *> *logRules;
@property(copy) NSDictionary *baseline; // original TZ/TZFILE, never logged
@property(copy) NSDictionary<NSString *, NSString *> *environment; // resolved launch values, never logged
@end

@interface TZDecision : NSObject
@property(strong) TZRule *rule;
@property(strong) TZSession *session;
@property BOOL ask;
@property BOOL inherited;
@end

@interface TZProgramPolicy : NSObject
@property(readonly) NSArray<TZRule *> *rules;
@property(readonly) BOOL esEnabled;
@property(readonly) NSString *defaultMode; // system | fixed
@property(readonly) NSString *defaultZone;
+ (instancetype)policyWithDictionary:(NSDictionary *)dictionary error:(NSError **)error;
- (NSDictionary *)dictionary;
- (TZDecision *)decisionForPath:(NSString *)path invokedPath:(NSString *)invoked script:(NSString *)script parent:(TZSession *)parent;
- (BOOL)loggingEnabledForSession:(TZSession *)session;
@end
