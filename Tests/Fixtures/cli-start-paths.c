// Test driver only: production injection must not depend on this parent.
#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int await_child(const char *name, pid_t pid) {
    int status;
    pid_t result;
    do { result = waitpid(pid, &status, 0); } while (result < 0 && errno == EINTR);
    int ok = result == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    printf("%s: %s\n", name, ok ? "PASS" : "FAIL");
    return !ok;
}

static int spawn_fixture(const char *name, const char *executable, char **args, char **env) {
    pid_t pid;
    int error = posix_spawn(&pid, executable, NULL, NULL, args, env);
    if (error) {
        fprintf(stderr, "%s: posix_spawn error=%d\n", name, error);
        return 1;
    }
    return await_child(name, pid);
}

int main(int argc, char **argv) {
    if (argc != 2 && argc != 3) {
        fprintf(stderr, "usage: cli-start-paths absolute-fixture-path [epoch-offset-seconds]\n");
        return 2;
    }
    setbuf(stdout, NULL);
    char *offset = argc == 3 ? argv[2] : "32400";
    char *args[] = {argv[1], offset, NULL};
    char *empty[] = {NULL};
    int failures = spawn_fixture("posix_spawn inherited env", argv[1], args, environ);
    failures += spawn_fixture("posix_spawn empty env", argv[1], args, empty);
    pid_t pid = fork();
    if (pid == 0) {
        execve(argv[1], args, empty);
        _exit(127);
    }
    if (pid < 0) failures++;
    else failures += await_child("fork + execve empty env", pid);
    char *shell_args[] = {"/bin/zsh", "-f", "-c", "exec \"$1\" \"$2\"", "cli-test", argv[1], offset, NULL};
    failures += spawn_fixture("shell exec empty env", "/bin/zsh", shell_args, empty);
    printf("CLI automatic-injection acceptance: %s (%d failed paths)\n",
           failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}
