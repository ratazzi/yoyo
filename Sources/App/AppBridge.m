#import "AppBridge.h"
#import "program-policy.h"
#import "control-channel.h"
NSDictionary *TZNormalizePolicy(NSDictionary *value) {
    return [TZProgramPolicy policyWithDictionary:value error:nil].dictionary;
}
NSString *TZPolicyError(NSDictionary *value) {
    NSError *error; [TZProgramPolicy policyWithDictionary:value error:&error]; return error.localizedDescription;
}
NSDictionary *TZControl(NSString *path, NSDictionary *request) {
    return tz_control_request(path, request, nil);
}
