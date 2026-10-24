#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

/* libc evaluates TZif POSIX footers beyond the final stored transition. */
int phobos_local_hour(int64_t seconds, int *hour) {
    time_t timestamp = (time_t)seconds;
    struct tm local;
    if ((int64_t)timestamp != seconds) return EOVERFLOW;
    if (localtime_r(&timestamp, &local) == NULL) return errno ? errno : EINVAL;
    *hour = local.tm_hour;
    return 0;
}

size_t phobos_local_ctime(int64_t seconds, char *buffer, size_t capacity) {
    static const char *days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
    static const char *months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    time_t timestamp = (time_t)seconds;
    struct tm local;
    if ((int64_t)timestamp != seconds || localtime_r(&timestamp, &local) == NULL)
        return 0;
    int length = snprintf(buffer, capacity, "%s %s %2d %02d:%02d:%02d %" PRId64,
                          days[local.tm_wday], months[local.tm_mon], local.tm_mday,
                          local.tm_hour, local.tm_min, local.tm_sec,
                          (int64_t)local.tm_year + 1900);
    return length < 0 || (size_t)length >= capacity ? 0 : (size_t)length;
}

size_t phobos_local_strftime(int64_t seconds, char *buffer, size_t capacity,
                            const char *format) {
    time_t timestamp = (time_t)seconds;
    struct tm local;
    if ((int64_t)timestamp != seconds || localtime_r(&timestamp, &local) == NULL)
        return 0;
    return strftime(buffer, capacity, format, &local);
}
