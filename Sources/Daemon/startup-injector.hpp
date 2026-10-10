#pragma once
#include <mach/mach.h>
#include <string>
#include <map>

struct StartupTimezone {
    std::string zone; // empty restores the normal environment without injecting
    std::string previous_zone;
    std::map<std::string, std::string> baseline;
    std::map<std::string, std::string> extra;
};

// Rewrites startup argv/env/apple pointer vectors without changing SP or executable code.
// No fallback bypasses code signing or patches dyld policy.
void inject_startup_environment(pid_t pid, const std::string &library, const std::string &zone);
void configure_startup_environment(pid_t pid, const std::string &library, const StartupTimezone &policy);
void test_startup_stack_rewrite();
