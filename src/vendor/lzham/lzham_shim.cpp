// Thin C wrapper over the vendored LZHAM decompressor (public-domain / zlib).
// Exposes one entry point unityz calls for UnityFS block compression type 4.
#include "lzham_decomp.h"
#include "lzham_core.h"
#include <string.h>

namespace lzham {
extern lzham_decompress_status_t LZHAM_CDECL lzham_lib_decompress_memory(
    const lzham_decompress_params*, lzham_uint8*, size_t*, const lzham_uint8*, size_t, lzham_uint32*);
}

/// Decompresses an LZHAM block. Returns 0 on success. `dst_len` in/out.
extern "C" int lzham_unpack(
    const unsigned char* src, unsigned src_len,
    unsigned char* dst, unsigned* dst_len, unsigned dict_size_log2) {
    lzham_decompress_params p;
    memset(&p, 0, sizeof(p));
    p.m_struct_size = sizeof(p);
    p.m_dict_size_log2 = dict_size_log2;
    p.m_decompress_flags = LZHAM_DECOMP_FLAG_COMPUTE_ADLER32;
    size_t dl = *dst_len;
    lzham_decompress_status_t st =
        lzham::lzham_lib_decompress_memory(&p, dst, &dl, src, src_len, NULL);
    *dst_len = (unsigned)dl;
    return st == LZHAM_DECOMP_STATUS_SUCCESS ? 0 : 1;
}
