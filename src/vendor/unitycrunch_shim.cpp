// Zig-facing wrapper around the vendored Unity crunch decompressor
// (src/vendor/unitycrunch/crn_decomp.h, ZLIB license, Richard Geldreich /
// Binomial LLC). Decompresses one mip level of a crunch-compressed
// texture into raw ETC1/ETC2/DXT blocks, which the Zig texture decoder
// then converts to RGBA.
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cassert>
#include <algorithm>
#include <utility>
#include "unitycrunch/crn_decomp.h"

extern "C" {

// Decompresses `level` of a crunch stream; on success `*ret` is a
// malloc'd buffer the caller frees with unitycrunch_free, `*ret_size`
// its byte length. Returns 1 on success, 0 on failure.
int unitycrunch_unpack(const uint8_t* data, uint32_t data_size, uint32_t level, void** ret, uint32_t* ret_size) {
    unitycrnd::crn_texture_info info;
    if (!unitycrnd::crnd_get_texture_info(data, data_size, &info)) return 0;

    uint32_t width = info.m_width >> level;
    if (width < 1) width = 1;
    uint32_t height = info.m_height >> level;
    if (height < 1) height = 1;
    uint32_t blocks_x = (width + 3) >> 2;
    if (blocks_x < 1) blocks_x = 1;
    uint32_t blocks_y = (height + 3) >> 2;
    if (blocks_y < 1) blocks_y = 1;

    const uint32_t bpp = unitycrnd::crnd_get_bytes_per_dxt_block(info.m_format);
    const uint32_t row_pitch = blocks_x * bpp;
    const uint32_t total = row_pitch * blocks_y;

    void* out = std::malloc(total);
    if (!out) return 0;

    unitycrnd::crnd_unpack_context ctx = unitycrnd::crnd_unpack_begin(data, data_size);
    if (!ctx) {
        std::free(out);
        return 0;
    }
    const bool ok = unitycrnd::crnd_unpack_level(ctx, &out, total, row_pitch, level);
    unitycrnd::crnd_unpack_end(ctx);
    if (!ok) {
        std::free(out);
        return 0;
    }
    *ret = out;
    *ret_size = total;
    return 1;
}

void unitycrunch_free(void* p) {
    std::free(p);
}

} // extern "C"
