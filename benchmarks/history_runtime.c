#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    unsigned char input[4];
    if (fread(input, 1, sizeof(input), stdin) != sizeof(input)) return 1;
    const uint32_t raw_limit = (uint32_t)input[0] + UINT32_C(256) * input[1]
        + UINT32_C(65536) * input[2] + UINT32_C(16777216) * input[3];
    if (raw_limit < 2 || raw_limit > INT32_MAX) return 1;
    const int32_t limit = (int32_t)raw_limit;

    int32_t *composite = malloc(((size_t)limit + 1) * sizeof(*composite));
    if (composite == NULL) return 1;
    for (int32_t index = 0; index <= limit; ++index) composite[index] = 0;
    for (int32_t factor = 2; factor * factor <= limit; ++factor) {
        if (composite[factor] == 0) {
            for (int32_t multiple = factor * factor; multiple <= limit; multiple += factor)
                composite[multiple] = 1;
        }
    }
    int32_t count = 0;
    for (int32_t number = 2; number <= limit; ++number) {
        if (composite[number] == 0) ++count;
    }
    free(composite);
    if (printf("%" PRId32 "\n", count) < 0) return 1;
    return 0;
}