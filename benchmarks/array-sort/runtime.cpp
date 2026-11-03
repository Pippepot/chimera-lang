#include <algorithm>
#include <cstdint>

// A separate translation unit without LTO preserves the runtime callback
// boundary, rather than letting the caller expose its concrete function.
void runtime_sort(std::int32_t *first, std::int32_t *last,
                  bool (*before)(std::int32_t, std::int32_t), bool stable) {
    if (stable)
        std::stable_sort(first, last, before);
    else
        std::sort(first, last, before);
}
