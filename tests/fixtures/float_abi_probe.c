#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern uint64_t probe_zig_value_bits(int index);
extern uint64_t probe_zig_add_bits(uint64_t a, uint64_t b);

__attribute__((noinline)) double probe_value(int index) {
    static const double values[] = {1.25, -2.5, 1792373447.904835, 7879.922059997552};
    return values[index & 3];
}

__attribute__((noinline)) double probe_add(double a, double b) {
    return a + b;
}

static uint64_t bits(double value) {
    uint64_t result;
    memcpy(&result, &value, sizeof(result));
    return result;
}

int probe_check(void) {
    int failures = 0;
    for (int index = 0; index < 4; index++) {
        const uint64_t expected = bits(probe_value(index));
        const uint64_t actual = probe_zig_value_bits(index);
        printf("return[%d] c=%016" PRIx64 " zig=%016" PRIx64 "\n", index, expected, actual);
        failures += actual != expected;
    }
    const uint64_t expected = bits(probe_add(1.25, -2.5));
    const uint64_t actual = probe_zig_add_bits(bits(1.25), bits(-2.5));
    printf("add c=%016" PRIx64 " zig=%016" PRIx64 "\n", expected, actual);
    failures += actual != expected;
    return failures;
}
