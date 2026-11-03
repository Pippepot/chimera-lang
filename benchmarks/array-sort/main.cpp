#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>

#ifndef ARRAY_SIZE
#define ARRAY_SIZE 65536
#endif

void runtime_sort(std::int32_t *first, std::int32_t *last,
                  bool (*before)(std::int32_t, std::int32_t), bool stable);

static bool before(std::int32_t left, std::int32_t right) {
    return left < right;
}

int main(int argc, char **argv) {
    if (argc != 2 || (std::strcmp(argv[1], "sort") != 0 &&
                      std::strcmp(argv[1], "stable_sort") != 0 &&
                      std::strcmp(argv[1], "sort-runtime") != 0 &&
                      std::strcmp(argv[1], "stable_sort-runtime") != 0))
        return 1;
    const bool stable = std::strcmp(argv[1], "stable_sort") == 0 ||
                        std::strcmp(argv[1], "stable_sort-runtime") == 0;
    const bool runtime = std::strcmp(argv[1], "sort-runtime") == 0 ||
                         std::strcmp(argv[1], "stable_sort-runtime") == 0;
    unsigned char input[5];
    if (std::fread(input, 1, sizeof(input), stdin) != sizeof(input))
        return 1;
    const int pattern = input[0];
    const int rounds = input[1] + input[2] * 256;
    const int seed = input[3] + input[4] * 256;
    if (pattern > 4 || rounds == 0)
        return 1;
    std::array<std::int32_t, ARRAY_SIZE> values;
    std::int32_t checksum = 0;
    for (int round = 0; round < rounds; ++round) {
        std::int32_t state = (seed + round) % 65536;
        for (int index = 0; index < ARRAY_SIZE; ++index) {
            state = (state * 25173 + 13849) % 65536;
            std::int32_t value = state;
            if (pattern == 1)
                value = index;
            else if (pattern == 2)
                value = ARRAY_SIZE - 1 - index;
            else if (pattern == 3)
                value = state % 16;
            else if (pattern == 4)
                value = ((ARRAY_SIZE - 1) / 256 - index / 256) * 256 + index % 256;
            values[index] = value;
        }
        if (runtime)
            runtime_sort(values.data(), values.data() + values.size(), before, stable);
        else if (stable)
            std::stable_sort(values.begin(), values.end());
        else
            std::sort(values.begin(), values.end());
        for (int index = 0; index < ARRAY_SIZE; ++index) {
            if (index > 0 && values[index - 1] > values[index])
                return 3;
            checksum = (checksum * 31 + values[index]) % 1000003;
        }
    }
    std::printf("%d\n", checksum);
}
