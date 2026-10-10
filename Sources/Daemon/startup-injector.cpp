#include "startup-injector.hpp"
#include <mach-o/loader.h>
#include <mach/mach_vm.h>
#include <mach/arm/thread_state.h>
#include <mach/i386/thread_state.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace {
using Word = uint64_t;
void check(kern_return_t result, const char *step) {
    if (result != KERN_SUCCESS) throw std::runtime_error(std::string(step) + ": " + mach_error_string(result));
}
void read_memory(task_t task, Word address, void *bytes, size_t size) {
    mach_vm_size_t copied = 0;
    check(mach_vm_read_overwrite(task, address, size, (mach_vm_address_t)bytes, &copied), "read target memory");
    if (copied != size) throw std::runtime_error("short target memory read");
}
Word read_word(task_t task, Word &cursor) {
    Word value;
    read_memory(task, cursor, &value, sizeof(value));
    cursor += sizeof(value);
    return value;
}
std::string read_string(task_t task, Word address, size_t &budget) {
    std::string result;
    while (budget && result.size() < 65536) {
        std::array<char, 256> bytes;
        size_t count = std::min({bytes.size(), budget, (size_t)(4096 - address % 4096), 65536 - result.size()});
        read_memory(task, address, bytes.data(), count);
        auto end = std::find(bytes.begin(), bytes.begin() + count, '\0');
        result.append(bytes.begin(), end);
        if (end != bytes.begin() + count) { budget -= (size_t)(end - bytes.begin()) + 1; return result; }
        address += count;
        budget -= count;
    }
    throw std::runtime_error("startup string limit exceeded");
}
std::vector<std::string> read_vector(task_t task, Word &cursor, size_t &budget) {
    std::vector<std::string> result;
    for (size_t i = 0; i < 4096; i++) {
        Word pointer = read_word(task, cursor);
        if (!pointer) return result;
        result.push_back(read_string(task, pointer, budget));
    }
    throw std::runtime_error("startup pointer limit exceeded");
}
void set_variable(std::vector<std::string> &environment, const std::string &key, const std::string &value, bool append) {
    std::string prefix = key + "=";
    auto found = std::find_if(environment.begin(), environment.end(), [&](const auto &s) { return s.starts_with(prefix); });
    if (found == environment.end()) environment.push_back(prefix + value);
    else if (append && found->size() > prefix.size()) *found += ":" + value;
    else *found = prefix + value;
}
void erase_variable(std::vector<std::string> &environment, const std::string &key) {
    std::string prefix = key + "=";
    std::erase_if(environment, [&](const auto &value) { return value.starts_with(prefix); });
}
void transform_environment(std::vector<std::string> &environment, const std::string &library, const StartupTimezone &policy) {
    // Remove only our own insertion, retaining unrelated DYLD libraries.
    auto dyld = std::find_if(environment.begin(), environment.end(), [](const auto &value) { return value.starts_with("DYLD_INSERT_LIBRARIES="); });
    bool inherited = false;
    if (dyld != environment.end()) {
        std::string source = dyld->substr(strlen("DYLD_INSERT_LIBRARIES=")), kept;
        size_t start = 0;
        while (start <= source.size()) {
            size_t end = source.find(':', start);
            std::string path = source.substr(start, end == std::string::npos ? end : end - start);
            if (path == library) inherited = true;
            else if (!path.empty()) { if (!kept.empty()) kept += ':'; kept += path; }
            if (end == std::string::npos) break;
            start = end + 1;
        }
        if (kept.empty()) erase_variable(environment, "DYLD_INSERT_LIBRARIES");
        else set_variable(environment, "DYLD_INSERT_LIBRARIES", kept, false);
    }
    for (const auto &value : environment) if (value.starts_with("TIMEZONE_LAB_SESSION=")) inherited = true;
    if (policy.zone.empty() && inherited) {
        for (const std::string key : {"TZ", "TZFILE"}) {
            auto found = std::find_if(environment.begin(), environment.end(), [&](const auto &value) { return value.starts_with(key + "="); });
            if (found == environment.end()) continue; // Respect an explicitly emptied child environment.
            std::string value = found->substr(key.size() + 1);
            bool ours = key == "TZ" ? value == policy.previous_zone : value.ends_with("/zoneinfo/" + policy.previous_zone);
            if (ours) {
                auto baseline = policy.baseline.find(key);
                if (baseline == policy.baseline.end()) erase_variable(environment, key);
                else set_variable(environment, key, baseline->second, false);
            }
        }
    }
    erase_variable(environment, "PROCESS_TIMEZONE");
    std::erase_if(environment, [](const auto &value) { return value.starts_with("TIMEZONE_LAB_"); });
    if (!policy.zone.empty()) {
        set_variable(environment, "DYLD_INSERT_LIBRARIES", library, true);
        set_variable(environment, "PROCESS_TIMEZONE", policy.zone, false);
        for (const auto &[key, value] : policy.extra) set_variable(environment, key, value, false);
    }
}
// On success, the relocated strings intentionally belong to the target until it exits.
Word rewrite(task_t task, Word stack, const std::string &library, const StartupTimezone &policy) {
    Word cursor = stack;
    Word header = read_word(task, cursor);
    Word argc = read_word(task, cursor);
    uint32_t magic;
    read_memory(task, header, &magic, sizeof(magic));
    if (magic != MH_MAGIC_64 || argc == 0 || argc > 4096) throw std::runtime_error("not a supported initial dyld stack");
    size_t budget = 1024 * 1024;
    auto args = read_vector(task, cursor, budget);
    auto environment = read_vector(task, cursor, budget);
    auto apple = read_vector(task, cursor, budget);
    if (args.size() != argc) throw std::runtime_error("startup argc mismatch");
    transform_environment(environment, library, policy);
    std::vector<char> strings;
    std::vector<Word> frame{header, argc};
    std::vector<size_t> pointer_slots;
    for (const auto *values : {&args, &environment, &apple}) {
        for (const auto &value : *values) {
            pointer_slots.push_back(frame.size());
            frame.push_back(strings.size());
            strings.insert(strings.end(), value.begin(), value.end());
            strings.push_back(0);
        }
        frame.push_back(0);
    }
    Word allocation = 0;
    check(mach_vm_allocate(task, &allocation, strings.size(), VM_FLAGS_ANYWHERE), "allocate target startup strings");
    try {
        check(mach_vm_write(task, allocation, (vm_offset_t)strings.data(), (mach_msg_type_number_t)strings.size()), "write target startup strings");
        for (size_t slot : pointer_slots) frame[slot] += allocation;
        std::vector<char> original(frame.size() * sizeof(Word));
        read_memory(task, stack, original.data(), original.size());
        kern_return_t result = mach_vm_write(task, stack, (vm_offset_t)frame.data(), (mach_msg_type_number_t)original.size());
        if (result != KERN_SUCCESS) {
            // Deny execution if this cannot be restored; caller treats any exception as failure.
            mach_vm_write(task, stack, (vm_offset_t)original.data(), (mach_msg_type_number_t)original.size());
            check(result, "write target startup vectors");
        }
    } catch (...) {
        mach_vm_deallocate(task, allocation, strings.size());
        throw;
    }
    return allocation;
}
}

void configure_startup_environment(pid_t pid, const std::string &library, const StartupTimezone &policy) {
    task_t task = MACH_PORT_NULL;
    check(task_for_pid(mach_task_self(), pid, &task), "task_for_pid");
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t count = 0;
    try {
        check(task_threads(task, &threads, &count), "task_threads");
        if (count != 1) throw std::runtime_error("target is not at single-thread startup");
        Word stack;
#if defined(__arm64__)
        arm_thread_state64_t state;
        mach_msg_type_number_t size = ARM_THREAD_STATE64_COUNT;
        check(thread_get_state(threads[0], ARM_THREAD_STATE64, (thread_state_t)&state, &size), "thread_get_state");
#if __has_feature(ptrauth_calls)
        check(thread_convert_thread_state(threads[0], THREAD_CONVERT_THREAD_STATE_TO_SELF, ARM_THREAD_STATE64,
                                         (thread_state_t)&state, size, (thread_state_t)&state, &size), "convert thread state");
#endif
        // A non-PAC arm64 caller reads SP directly. No register is written back.
        stack = arm_thread_state64_get_sp(state);
#elif defined(__x86_64__)
        x86_thread_state64_t state;
        mach_msg_type_number_t size = x86_THREAD_STATE64_COUNT;
        check(thread_get_state(threads[0], x86_THREAD_STATE64, (thread_state_t)&state, &size), "thread_get_state");
        stack = state.__rsp;
#else
#error Unsupported architecture
#endif
        rewrite(task, stack, library, policy);
    } catch (...) {
        if (threads) {
            for (unsigned i = 0; i < count; i++) mach_port_deallocate(mach_task_self(), threads[i]);
            vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
        }
        mach_port_deallocate(mach_task_self(), task);
        throw;
    }
    for (unsigned i = 0; i < count; i++) mach_port_deallocate(mach_task_self(), threads[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    mach_port_deallocate(mach_task_self(), task);
}

void inject_startup_environment(pid_t pid, const std::string &library, const std::string &zone) {
    StartupTimezone policy; policy.zone = zone;
    configure_startup_environment(pid, library, policy);
}

void test_startup_stack_rewrite() {
    std::array<Word, 64> frame{};
    mach_header_64 header{};
    header.magic = MH_MAGIC_64;
    const char *arg = "fixture";
    const char *existing = "DYLD_INSERT_LIBRARIES=/existing.dylib";
    const char *unchanged = "KEEP=preserved";
    const char *apple = "executable_path=/fixture";
    frame[0] = (Word)&header; frame[1] = 1;
    frame[2] = (Word)arg; frame[3] = 0;
    frame[4] = (Word)existing; frame[5] = (Word)unchanged; frame[6] = 0;
    frame[7] = (Word)apple; frame[8] = 0;
    StartupTimezone policy; policy.zone = "Asia/Tokyo";
    Word allocation = rewrite(mach_task_self(), (Word)frame.data(), "/test.dylib", policy);
    Word cursor = (Word)&frame[2];
    size_t budget = 1024 * 1024;
    auto args = read_vector(mach_task_self(), cursor, budget);
    auto environment = read_vector(mach_task_self(), cursor, budget);
    auto apples = read_vector(mach_task_self(), cursor, budget);
    bool valid = frame[0] == (Word)&header && frame[1] == 1 && args == std::vector<std::string>{arg} &&
        environment == std::vector<std::string>{"DYLD_INSERT_LIBRARIES=/existing.dylib:/test.dylib", unchanged, "PROCESS_TIMEZONE=Asia/Tokyo"} &&
        apples == std::vector<std::string>{apple};
    mach_vm_deallocate(mach_task_self(), allocation, 4096);
    if (!valid) throw std::runtime_error("startup stack preservation test failed");
    std::vector<std::string> inherited{"DYLD_INSERT_LIBRARIES=/other.dylib:/test.dylib", "PROCESS_TIMEZONE=Asia/Tokyo",
        "TIMEZONE_LAB_SESSION=parent", "TZ=Asia/Tokyo", "TZFILE=/var/db/timezone/zoneinfo/Asia/Tokyo", "KEEP=yes"};
    StartupTimezone restore; restore.previous_zone = "Asia/Tokyo"; restore.baseline["TZ"] = "Australia/Melbourne";
    transform_environment(inherited, "/test.dylib", restore);
    if (inherited != std::vector<std::string>{"DYLD_INSERT_LIBRARIES=/other.dylib", "TZ=Australia/Melbourne", "KEEP=yes"})
        throw std::runtime_error("default child did not restore the original timezone environment");
    std::vector<std::string> empty;
    transform_environment(empty, "/test.dylib", restore);
    if (!empty.empty()) throw std::runtime_error("empty default environment was modified");
}
