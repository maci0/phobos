#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int phobos_local_hour(int64_t seconds, int *hour);

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end;
    int64_t timestamp = strtoll(argv[1], &end, 10);
    if (*end != '\0') return 2;
    int hour;
    if (phobos_local_hour(timestamp, &hour) != 0) return 1;
    printf("%d\n", hour);
    return 0;
}
