#include "startup-injector.hpp"
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>
#include <cstdio>
#include <exception>

int main(int argc, char **argv) {
    if (argc != 3) { std::fprintf(stderr, "usage: test-suspended-exec fixture dylib\n"); return 2; }
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_START_SUSPENDED);
    char *args[] = {argv[1], nullptr};
    char *environment[] = {nullptr};
    pid_t pid;
    int result = posix_spawn(&pid, argv[1], nullptr, &attributes, args, environment);
    posix_spawnattr_destroy(&attributes);
    if (result) { std::fprintf(stderr, "posix_spawn failed: %d\n", result); return 1; }
    try {
        inject_startup_environment(pid, argv[2], "Asia/Tokyo");
        if (kill(pid, SIGCONT)) throw std::runtime_error("SIGCONT failed");
    } catch (const std::exception &error) {
        std::fprintf(stderr, "startup injection failed: %s\n", error.what());
        kill(pid, SIGKILL);
        waitpid(pid, nullptr, 0);
        return 1;
    }
    int status;
    waitpid(pid, &status, 0);
    bool pass = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    std::printf("suspended empty-environment CLI: %s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
