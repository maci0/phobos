#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdint.h>
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
