#include <stdint.h>
#include <sys/statvfs.h>

/* Keep libc's architecture-specific filesystem layout out of Zig. */
void phobos_disk_usage(const char *path, uint64_t *total, uint64_t *used,
                      uint64_t *available) {
    struct statvfs fs;
    if (statvfs(path, &fs) != 0) return;
    *total = (uint64_t)fs.f_blocks * fs.f_frsize;
    *used = (uint64_t)(fs.f_blocks - fs.f_bfree) * fs.f_frsize;
    *available = (uint64_t)fs.f_bavail * fs.f_frsize;
}
