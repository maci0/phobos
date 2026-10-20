#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int phobos_local_hour(int64_t seconds, int *hour);
size_t phobos_local_ctime(int64_t seconds, char *buffer, size_t capacity);

int main(int argc, char **argv) {
    if (argc != 2 && argc != 3) return 2;
    char *end;
    int64_t timestamp = strtoll(argv[1], &end, 10);
    if (*end != '\0') return 2;
    if (argc == 3) {
        if (strcmp(argv[2], "ctime") != 0) return 2;
        char buffer[64];
        if (phobos_local_ctime(timestamp, buffer, sizeof buffer) == 0) return 1;
        puts(buffer);
        return 0;
    }
    int hour;
    if (phobos_local_hour(timestamp, &hour) != 0) return 1;
    printf("%d\n", hour);
    return 0;
}
