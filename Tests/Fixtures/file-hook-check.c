#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <dlfcn.h>

static void check_icu(void) {
    int32_t (*get)(uint16_t *, int32_t, int32_t *) = dlsym(RTLD_DEFAULT, "ucal_getDefaultTimeZone");
    void (*set)(const uint16_t *, int32_t *) = dlsym(RTLD_DEFAULT, "ucal_setDefaultTimeZone");
    void *(*calendar_open)(const uint16_t *, int32_t, const char *, int32_t, int32_t *) = dlsym(RTLD_DEFAULT, "ucal_open");
    int32_t (*calendar_zone)(void *, uint16_t *, int32_t, int32_t *) = dlsym(RTLD_DEFAULT, "ucal_getTimeZoneID");
    void (*calendar_close)(void *) = dlsym(RTLD_DEFAULT, "ucal_close");
    assert(get && set && calendar_open && calendar_zone && calendar_close);
    const char *expected = getenv("TZ");
    assert(expected);
    uint16_t name[128];
    int32_t error = 0;
    void *calendar = calendar_open(NULL, 0, "en_US_POSIX", 0, &error);
    assert(calendar && error <= 0);
    int32_t length = calendar_zone(calendar, name, 128, &error);
    assert(error <= 0 && length == (int32_t)strlen(expected));
    for (int32_t i = 0; i < length; i++) assert(name[i] == (unsigned char)expected[i]);
    calendar_close(calendar);
    error = 0;
    assert(get(NULL, 0, &error) == length && error == 15);
    error = 0;
    name[length] = 0x7777;
    assert(get(name, length, &error) == length && error == -124 && name[length] == 0x7777);
    error = 0;
    const uint16_t utc[] = {'U', 'T', 'C', 0};
    set(utc, &error);
    assert(error <= 0);
    assert(get(name, 128, &error) == length && error <= 0 && name[length] == 0);
    for (int32_t i = 0; i < length; i++) assert(name[i] == (unsigned char)expected[i]);
}

int main(void) {
    check_icu();
    assert(syscall(SYS_getpid) == getpid());
    char directory[] = "/private/tmp/timezone-files-XXXXXX";
    assert(mkdtemp(directory));
    int dir = open(directory, O_RDONLY | O_DIRECTORY);
    assert(dir >= 0);
    char path[1024];
    snprintf(path, sizeof(path), "%s/localtime", directory);
    int fd = syscall(SYS_open, path, O_CREAT | O_EXCL | O_RDWR, 0600);
    assert(fd >= 0);
    const char content[] = "unrelated file preserved";
    assert(syscall(SYS_write, fd, content, sizeof(content)) == sizeof(content));
    assert(syscall(SYS_close, fd) == 0);
    fd = syscall(SYS_openat, dir, "localtime", O_RDONLY);
    assert(fd >= 0);
    char data[128];
    assert(syscall(SYS_read, fd, data, sizeof(data)) == sizeof(content));
    assert(!memcmp(data, content, sizeof(content)));
    assert(close(fd) == 0);
    assert(symlinkat("localtime", dir, "link") == 0);
    assert(readlinkat(dir, "link", data, sizeof(data)) == 9);
    assert(!memcmp(data, "localtime", 9));
    assert(syscall(SYS_readlinkat, dir, "link", data, sizeof(data)) == 9);
    assert(!memcmp(data, "localtime", 9));
    assert(symlinkat("/etc/localtime", dir, "system-link") == 0);
    assert(readlinkat(dir, "system-link", data, sizeof(data)) == 14);
    assert(!memcmp(data, "/etc/localtime", 14));
    fd = openat(dir, "system-link", O_RDONLY);
    assert(fd >= 0);
    struct stat expected_file, alias_file;
    assert(stat("/etc/localtime", &expected_file) == 0 && fstat(fd, &alias_file) == 0);
    assert(expected_file.st_ino == alias_file.st_ino && expected_file.st_size == alias_file.st_size);
    assert(close(fd) == 0);
    char one[2] = {'?', '!'};
    assert(readlink("/etc/localtime", one, 1) == 1 && one[0] == '/' && one[1] == '!');
    errno = 0;
    assert(readlink("/etc/localtime", one, 0) == -1 && errno == EINVAL);
    errno = 0;
    assert(open("/etc/localtime", O_RDONLY | O_NOFOLLOW) == -1 && errno == ELOOP);
    struct stat metadata;
    assert(lstat("/etc/localtime", &metadata) == 0 && S_ISLNK(metadata.st_mode));
    ssize_t length = readlink("/etc/localtime", data, sizeof(data));
    assert(length > 0 && metadata.st_size == length);
    assert(syscall(SYS_lstat64, "/etc/localtime", &metadata) == 0 && metadata.st_size == length);
    int etc = open("/etc", O_RDONLY | O_DIRECTORY);
    assert(etc >= 0);
    assert(syscall(SYS_fstatat64, etc, "localtime", &metadata, AT_SYMLINK_NOFOLLOW) == 0 && metadata.st_size == length);
    assert(close(etc) == 0);
    assert(unlinkat(dir, "link", 0) == 0);
    assert(unlinkat(dir, "system-link", 0) == 0);
    assert(unlinkat(dir, "localtime", 0) == 0);
    assert(close(dir) == 0 && rmdir(directory) == 0);
    puts("Filesystem hooks preserve unrelated IO, syscall forwarding, readlink and no-follow semantics: PASS");
    return 0;
}
