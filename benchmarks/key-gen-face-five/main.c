#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

static int generate_keys(int32_t last) {
    int32_t keys[13] = {0, 1, 5};
    int32_t sums[50000] = {0};
    for (int32_t key_index = 3; key_index <= last; ++key_index) {
        int32_t candidate = keys[key_index - 1] + 1;
        for (;;) {
            keys[key_index] = candidate;
            int32_t count = 0;
            for (int32_t face1 = 0; face1 <= key_index; ++face1) {
                for (int32_t face2 = face1; face2 <= key_index; ++face2) {
                    for (int32_t face3 = face2; face3 <= key_index; ++face3) {
                        for (int32_t face4 = face3; face4 <= key_index; ++face4) {
                            for (int32_t face5 = face4; face5 <= key_index; ++face5) {
                                if (face1 != face5) {
                                    sums[count] = keys[face1] + keys[face2] + keys[face3]
                                        + keys[face4] + keys[face5];
                                    ++count;
                                }
                            }
                        }
                    }
                }
            }
            int valid = 1;
            for (int32_t left = 0; valid && left < count - 1; ++left) {
                for (int32_t right = left + 1; valid && right < count; ++right) {
                    if (sums[left] == sums[right]) valid = 0;
                }
            }
            if (valid) break;
            ++candidate;
        }
    }
    for (int32_t key_index = 0; key_index <= last; ++key_index) {
        if (printf("%" PRId32 "\n", keys[key_index]) < 0) return 1;
    }
    return 0;
}

int main(void) {
    unsigned char input;
    if (fread(&input, 1, 1, stdin) != 1) return 1;
    if (input < 3 || input > 12) return 1;
    return generate_keys(input);
}