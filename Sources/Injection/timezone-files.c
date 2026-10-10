#include "timezone-files.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/attr.h>
#include <sys/syscall.h>
#include <unistd.h>

static char zone_link[PATH_MAX];
static char zone_file[PATH_MAX];

const char *timezone_files_path(void) { return zone_file[0] ? zone_file : NULL; }

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *new_fn; const void *old_fn; } \
    pair_##original __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)&replacement, (const void *)&original \
    }

static _Thread_local int probing_alias;
static int localtime_path_impl(int directory, const char *path, int follow_alias, unsigned depth) {
    if (!zone_file[0] || !path || !*path) return 0;
    if (!strcmp(path, "/etc/localtime") || !strcmp(path, "/private/etc/localtime")) return 1;
    if (depth >= 32) return 0;
    char absolute[PATH_MAX];
    if (*path == '/') {
        if (strlcpy(absolute, path, sizeof(absolute)) >= sizeof(absolute)) return 0;
    } else {
        char base[PATH_MAX];
        if (directory == AT_FDCWD) {
            if (!getcwd(base, sizeof(base))) return 0;
        } else if (fcntl(directory, F_GETPATH, base) < 0) return 0;
        if (snprintf(absolute, sizeof(absolute), "%s/%s", base, path) >= (int)sizeof(absolute)) return 0;
    }
    char parent[PATH_MAX];
    strlcpy(parent, absolute, sizeof(parent));
    char *separator = strrchr(parent, '/');
    if (!separator) return 0;
    int final_is_localtime = !strcmp(separator + 1, "localtime");
    if (separator == parent) parent[1] = 0; else *separator = 0;
    if (final_is_localtime) {
        char resolved[PATH_MAX];
        if (realpath(parent, resolved) && (!strcmp(resolved, "/etc") || !strcmp(resolved, "/private/etc"))) return 1;
    }
    if (!follow_alias) return 0;
    char target[PATH_MAX];
    ssize_t count = readlink(absolute, target, sizeof(target) - 1);
    if (count < 0) return 0;
    target[count] = 0;
    if (target[0] == '/') return localtime_path_impl(AT_FDCWD, target, 1, depth + 1);
    char combined[PATH_MAX];
    if (snprintf(combined, sizeof(combined), "%s/%s", parent, target) >= (int)sizeof(combined)) return 0;
    return localtime_path_impl(AT_FDCWD, combined, 1, depth + 1);
}
static int match_path(int directory, const char *path, int follow_alias) {
    if (probing_alias) return 0;
    probing_alias = 1;
    int saved = errno;
    int result = localtime_path_impl(directory, path, follow_alias, 0);
    errno = saved;
    probing_alias = 0;
    return result;
}
static int localtime_path(int directory, const char *path) { return match_path(directory, path, 1); }
static int localtime_link(int directory, const char *path) { return match_path(directory, path, 0); }

static const char *read_path(int directory, const char *path, int flags) {
    if ((flags & O_ACCMODE) == O_RDONLY && !(flags & (O_CREAT | O_TRUNC)) && localtime_path(directory, path))
        return zone_file;
    return path;
}

const char *timezone_files_replacement(int directory, const char *path) {
    return localtime_path(directory, path) ? zone_file : NULL;
}

static int wrapped_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list args; va_start(args, flags); mode = va_arg(args, int); va_end(args); }
    const char *mapped = read_path(AT_FDCWD, path, flags);
    if (mapped != path && (flags & O_NOFOLLOW)) { errno = ELOOP; return -1; }
    return open(mapped, flags, mode);
}
static int wrapped_openat(int directory, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list args; va_start(args, flags); mode = va_arg(args, int); va_end(args); }
    const char *mapped = read_path(directory, path, flags);
    if (mapped != path && (flags & O_NOFOLLOW)) { errno = ELOOP; return -1; }
    return openat(directory, mapped, flags, mode);
}
extern int original_open_nocancel(const char *, int, ...) __asm("_open$NOCANCEL");
extern int original_openat_nocancel(int, const char *, int, ...) __asm("_openat$NOCANCEL");
static int wrapped_open_nocancel(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list args; va_start(args, flags); mode = va_arg(args, int); va_end(args); }
    const char *mapped = read_path(AT_FDCWD, path, flags);
    if (mapped != path && (flags & O_NOFOLLOW)) { errno = ELOOP; return -1; }
    return original_open_nocancel(mapped, flags, mode);
}
static int wrapped_openat_nocancel(int directory, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list args; va_start(args, flags); mode = va_arg(args, int); va_end(args); }
    const char *mapped = read_path(directory, path, flags);
    if (mapped != path && (flags & O_NOFOLLOW)) { errno = ELOOP; return -1; }
    return original_openat_nocancel(directory, mapped, flags, mode);
}

static ssize_t virtual_link(char *buffer, size_t capacity) {
    if (!capacity) { errno = EINVAL; return -1; }
    if (!buffer) { errno = EFAULT; return -1; }
    size_t count = strlen(zone_link);
    if (count > capacity) count = capacity;
    memcpy(buffer, zone_link, count); // readlink never adds a terminator.
    return (ssize_t)count;
}
static ssize_t wrapped_readlink(const char *path, char *buffer, size_t capacity) {
    return localtime_link(AT_FDCWD, path) ? virtual_link(buffer, capacity) : readlink(path, buffer, capacity);
}
static ssize_t wrapped_readlinkat(int directory, const char *path, char *buffer, size_t capacity) {
    return localtime_link(directory, path) ? virtual_link(buffer, capacity) : readlinkat(directory, path, buffer, capacity);
}
static char *wrapped_realpath(const char *path, char *resolved) {
    return realpath(localtime_path(AT_FDCWD, path) ? zone_file : path, resolved);
}
extern char *original_realpath_extension(const char *, char *) __asm("_realpath$DARWIN_EXTSN");
static char *wrapped_realpath_extension(const char *path, char *resolved) {
    return original_realpath_extension(localtime_path(AT_FDCWD, path) ? zone_file : path, resolved);
}
static FILE *wrapped_fopen(const char *path, const char *mode) {
    return fopen(mode && mode[0] == 'r' && !strchr(mode, '+') && localtime_path(AT_FDCWD, path) ? zone_file : path, mode);
}
extern FILE *original_fopen_extension(const char *, const char *) __asm("_fopen$DARWIN_EXTSN");
static FILE *wrapped_fopen_extension(const char *path, const char *mode) {
    return original_fopen_extension(mode && mode[0] == 'r' && !strchr(mode, '+') && localtime_path(AT_FDCWD, path) ? zone_file : path, mode);
}
static int wrapped_stat(const char *path, struct stat *value) {
    return stat(localtime_path(AT_FDCWD, path) ? zone_file : path, value);
}
static int wrapped_lstat(const char *path, struct stat *value) {
    int result = lstat(path, value);
    if (result == 0 && localtime_link(AT_FDCWD, path)) value->st_size = (off_t)strlen(zone_link);
    return result;
}
static int wrapped_fstatat(int directory, const char *path, struct stat *value, int flags) {
    if (!localtime_path(directory, path)) return fstatat(directory, path, value, flags);
    if (flags & AT_SYMLINK_NOFOLLOW) {
        int result = fstatat(directory, path, value, flags);
        if (!result && localtime_link(directory, path)) value->st_size = (off_t)strlen(zone_link);
        return result;
    }
    return fstatat(directory, zone_file, value, flags);
}
static int wrapped_getattrlist(const char *path, struct attrlist *attributes, void *buffer, size_t size, unsigned long options) {
    return getattrlist(localtime_path(AT_FDCWD, path) && !(options & FSOPT_NOFOLLOW) ? zone_file : path,
                       attributes, buffer, size, options);
}
static int wrapped_getattrlistat(int directory, const char *path, struct attrlist *attributes, void *buffer, size_t size, unsigned long options) {
    return getattrlistat(directory, localtime_path(directory, path) && !(options & FSOPT_NOFOLLOW) ? zone_file : path,
                         attributes, buffer, size, options);
}

// Forward unknown variadic syscalls without touching registers or the argument stack.
// Known path syscalls enter a typed variadic dispatcher. This hooks the libc trampoline,
// not an application's independent inline kernel trap.
extern int timezone_filtered_syscall(int, ...);
__attribute__((visibility("hidden"))) int timezone_dispatch_syscall(int number, ...) {
    va_list args;
    va_start(args, number);
    int result = -1;
    if (number == SYS_open || number == SYS_open_nocancel) {
        const char *path = va_arg(args, const char *);
        int flags = va_arg(args, int);
        int mode = (flags & O_CREAT) ? va_arg(args, int) : 0;
        const char *mapped = read_path(AT_FDCWD, path, flags);
        if (mapped != path && (flags & O_NOFOLLOW)) errno = ELOOP;
        else result = syscall(number, mapped, flags, mode);
    } else if (number == SYS_openat || number == SYS_openat_nocancel) {
        int directory = va_arg(args, int);
        const char *path = va_arg(args, const char *);
        int flags = va_arg(args, int);
        int mode = (flags & O_CREAT) ? va_arg(args, int) : 0;
        const char *mapped = read_path(directory, path, flags);
        if (mapped != path && (flags & O_NOFOLLOW)) errno = ELOOP;
        else result = syscall(number, directory, mapped, flags, mode);
    } else if (number == SYS_readlink || number == SYS_readlinkat) {
        int directory = number == SYS_readlinkat ? va_arg(args, int) : AT_FDCWD;
        const char *path = va_arg(args, const char *);
        char *buffer = va_arg(args, char *);
        size_t capacity = va_arg(args, size_t);
        if (localtime_link(directory, path)) result = (int)virtual_link(buffer, capacity);
        else if (number == SYS_readlinkat) result = syscall(number, directory, path, buffer, capacity);
        else result = syscall(number, path, buffer, capacity);
    } else if (number == SYS_stat64 || number == SYS_lstat64) {
        const char *path = va_arg(args, const char *);
        struct stat *metadata = va_arg(args, struct stat *);
        int mapped = localtime_path(AT_FDCWD, path);
        result = syscall(number, mapped && number == SYS_stat64 ? zone_file : path, metadata);
        if (!result && number == SYS_lstat64 && localtime_link(AT_FDCWD, path)) metadata->st_size = (off_t)strlen(zone_link);
    } else if (number == SYS_fstatat64) {
        int directory = va_arg(args, int);
        const char *path = va_arg(args, const char *);
        struct stat *metadata = va_arg(args, struct stat *);
        int flags = va_arg(args, int);
        int mapped = localtime_path(directory, path);
        result = syscall(number, directory, mapped && !(flags & AT_SYMLINK_NOFOLLOW) ? zone_file : path, metadata, flags);
        if (!result && (flags & AT_SYMLINK_NOFOLLOW) && localtime_link(directory, path)) metadata->st_size = (off_t)strlen(zone_link);
    }
    va_end(args);
    return result;
}

#if defined(__arm64__)
__asm__(
    ".text\n.globl _timezone_filtered_syscall\n.p2align 2\n_timezone_filtered_syscall:\n"
    "cmp w0, #5\n b.eq Ltimezone_dispatch\n"
    "cmp w0, #398\n b.eq Ltimezone_dispatch\n"
    "cmp w0, #463\n b.eq Ltimezone_dispatch\n"
    "cmp w0, #464\n b.eq Ltimezone_dispatch\n"
    "cmp w0, #58\n b.eq Ltimezone_dispatch\n"
    "cmp w0, #473\n b.eq Ltimezone_dispatch\n"
    "cmp w0, #338\n b.eq Ltimezone_dispatch\n"
    "cmp w0, #340\n b.eq Ltimezone_dispatch\n"
    "cmp w0, #470\n b.eq Ltimezone_dispatch\n"
    "b _syscall\nLtimezone_dispatch:\n b _timezone_dispatch_syscall\n");
#elif defined(__x86_64__)
__asm__(
    ".text\n.globl _timezone_filtered_syscall\n_timezone_filtered_syscall:\n"
    "cmpl $5, %edi\n je _timezone_dispatch_syscall\n"
    "cmpl $398, %edi\n je _timezone_dispatch_syscall\n"
    "cmpl $463, %edi\n je _timezone_dispatch_syscall\n"
    "cmpl $464, %edi\n je _timezone_dispatch_syscall\n"
    "cmpl $58, %edi\n je _timezone_dispatch_syscall\n"
    "cmpl $473, %edi\n je _timezone_dispatch_syscall\n"
    "cmpl $338, %edi\n je _timezone_dispatch_syscall\n"
    "cmpl $340, %edi\n je _timezone_dispatch_syscall\n"
    "cmpl $470, %edi\n je _timezone_dispatch_syscall\n"
    "jmp _syscall\n");
#endif

INTERPOSE(wrapped_open, open);
INTERPOSE(wrapped_openat, openat);
INTERPOSE(wrapped_open_nocancel, original_open_nocancel);
INTERPOSE(wrapped_openat_nocancel, original_openat_nocancel);
INTERPOSE(wrapped_readlink, readlink);
INTERPOSE(wrapped_readlinkat, readlinkat);
INTERPOSE(wrapped_realpath, realpath);
INTERPOSE(wrapped_realpath_extension, original_realpath_extension);
INTERPOSE(wrapped_fopen, fopen);
INTERPOSE(wrapped_fopen_extension, original_fopen_extension);
INTERPOSE(wrapped_stat, stat);
INTERPOSE(wrapped_lstat, lstat);
INTERPOSE(wrapped_fstatat, fstatat);
INTERPOSE(wrapped_getattrlist, getattrlist);
INTERPOSE(wrapped_getattrlistat, getattrlistat);
INTERPOSE(timezone_filtered_syscall, syscall);

int timezone_files_configure(const char *zone) {
    char path[PATH_MAX], resolved[PATH_MAX];
    if (!zone || snprintf(path, sizeof(path), "/var/db/timezone/zoneinfo/%s", zone) >= (int)sizeof(path)) { errno = EINVAL; return -1; }
    if (!realpath(path, resolved)) return -1;
    struct stat metadata;
    if (stat(resolved, &metadata) || !S_ISREG(metadata.st_mode)) { errno = EINVAL; return -1; }
    strlcpy(zone_link, path, sizeof(zone_link));
    strlcpy(zone_file, resolved, sizeof(zone_file));
    return 0;
}
