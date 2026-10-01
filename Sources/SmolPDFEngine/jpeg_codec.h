#ifndef SMOLPDF_JPEG_CODEC_H
#define SMOLPDF_JPEG_CODEC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SmolJPEGInfo {
    int width, height, components;
    int adobe_marker;    // has an Adobe APP14 marker
    int adobe_transform; // its colour transform: 0 none, 1 YCbCr, 2 YCCK
    int ycck;            // stored as YCCK
    int progressive;
    int precision;       // bits per sample (8 or 12)
} SmolJPEGInfo;

// All functions return NULL (or 0) on failure. Returned buffers are malloc'ed; free() them.

int smol_jpeg_info(const unsigned char* data, size_t size, SmolJPEGInfo* info);

// Decodes to interleaved 8-bit samples: gray, RGB, or CMYK exactly as stored.
unsigned char* smol_jpeg_decode(const unsigned char* data, size_t size, SmolJPEGInfo* info);

// Encodes gray (1), RGB (3) or CMYK (4) samples. For CMYK, `like` (the source JPEG, may be NULL)
// decides the colour transform and markers so the result is read the same way as the source.
unsigned char* smol_jpeg_encode(
    const unsigned char* pixels, int width, int height, int components, int quality,
    const SmolJPEGInfo* like, size_t* out_size);

// Losslessly rewrites a JPEG with optimal Huffman tables and progressive scans (no pixel changes).
unsigned char* smol_jpeg_optimize(const unsigned char* data, size_t size, size_t* out_size);

#ifdef __cplusplus
}
#endif

#endif
