#include <errno.h>
#include <stdint.h>
#include <sys/statvfs.h>

/* Keep libc's architecture-specific filesystem layout out of Zig.
 * Returns 0 and fills the outputs, or the fstatvfs errno and leaves them
 * unchanged. */
int phobos_disk_usage(int fd, uint64_t *total, uint64_t *used,
                      uint64_t *available) {
    struct statvfs fs;
    if (fstatvfs(fd, &fs) != 0) return errno;
    *total = (uint64_t)fs.f_blocks * fs.f_frsize;
    *used = (uint64_t)(fs.f_blocks - fs.f_bfree) * fs.f_frsize;
    *available = (uint64_t)fs.f_bavail * fs.f_frsize;
    return 0;
}
