// JPEG decoding, encoding and lossless re-optimisation with mozjpeg.
// Written in C because libjpeg reports errors with longjmp, which must not cross C++ frames.

#include "jpeg_codec.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <jpeglib.h>

typedef struct {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
} ErrorManager;

static void on_error(j_common_ptr cinfo) {
    longjmp(((ErrorManager*)cinfo->err)->jump, 1);
}

static void on_message(j_common_ptr cinfo, int level) {
    (void)cinfo;
    (void)level;
}

static void install_errors(j_common_ptr cinfo, ErrorManager* err) {
    cinfo->err = jpeg_std_error(&err->pub);
    err->pub.error_exit = on_error;
    err->pub.emit_message = on_message;
}

// Refuse absurd dimensions before allocating (corrupt or hostile files).
static const unsigned long long max_pixels = 400ULL * 1000 * 1000;

int smol_jpeg_info(const unsigned char* data, size_t size, SmolJPEGInfo* info) {
    struct jpeg_decompress_struct cinfo;
    ErrorManager err;
    install_errors((j_common_ptr)&cinfo, &err);
    if (setjmp(err.jump)) {
        jpeg_destroy_decompress(&cinfo);
        return 0;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, data, (unsigned long)size);
    jpeg_read_header(&cinfo, TRUE);
    info->width = (int)cinfo.image_width;
    info->height = (int)cinfo.image_height;
    info->components = cinfo.num_components;
    info->adobe_marker = cinfo.saw_Adobe_marker;
    info->adobe_transform = cinfo.Adobe_transform;
    info->ycck = cinfo.jpeg_color_space == JCS_YCCK;
    info->progressive = cinfo.progressive_mode;
    info->precision = cinfo.data_precision;
    jpeg_destroy_decompress(&cinfo);
    return 1;
}

unsigned char* smol_jpeg_decode(const unsigned char* data, size_t size, SmolJPEGInfo* info) {
    struct jpeg_decompress_struct cinfo;
    ErrorManager err;
    unsigned char* volatile pixels = NULL;
    install_errors((j_common_ptr)&cinfo, &err);
    if (setjmp(err.jump)) {
        jpeg_destroy_decompress(&cinfo);
        free(pixels);
        return NULL;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, data, (unsigned long)size);
    jpeg_read_header(&cinfo, TRUE);
    if (cinfo.data_precision != 8 ||
        (unsigned long long)cinfo.image_width * cinfo.image_height > max_pixels) {
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }
    // Keep PDF semantics: YCbCr becomes RGB, YCCK becomes CMYK, everything else as stored.
    switch (cinfo.jpeg_color_space) {
    case JCS_GRAYSCALE: cinfo.out_color_space = JCS_GRAYSCALE; break;
    case JCS_YCbCr:
    case JCS_RGB: cinfo.out_color_space = JCS_RGB; break;
    case JCS_CMYK:
    case JCS_YCCK: cinfo.out_color_space = JCS_CMYK; break;
    default:
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }
    jpeg_start_decompress(&cinfo);
    size_t stride = (size_t)cinfo.output_width * cinfo.output_components;
    pixels = malloc(stride * cinfo.output_height);
    if (!pixels) {
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = pixels + stride * cinfo.output_scanline;
        jpeg_read_scanlines(&cinfo, &row, 1);
    }
    info->width = (int)cinfo.output_width;
    info->height = (int)cinfo.output_height;
    info->components = cinfo.output_components;
    info->adobe_marker = cinfo.saw_Adobe_marker;
    info->adobe_transform = cinfo.Adobe_transform;
    info->ycck = cinfo.jpeg_color_space == JCS_YCCK;
    info->progressive = cinfo.progressive_mode;
    info->precision = cinfo.data_precision;
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    return pixels;
}

unsigned char* smol_jpeg_encode(
    const unsigned char* pixels, int width, int height, int components, int quality,
    const SmolJPEGInfo* like, size_t* out_size) {
    struct jpeg_compress_struct cinfo;
    ErrorManager err;
    unsigned char* volatile out = NULL;
    unsigned long size = 0;
    install_errors((j_common_ptr)&cinfo, &err);
    if (setjmp(err.jump)) {
        jpeg_destroy_compress(&cinfo);
        free(out);
        return NULL;
    }
    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, (unsigned char**)&out, &size);
    cinfo.image_width = (JDIMENSION)width;
    cinfo.image_height = (JDIMENSION)height;
    cinfo.input_components = components;
    cinfo.in_color_space = components == 1 ? JCS_GRAYSCALE : components == 3 ? JCS_RGB : JCS_CMYK;
    // mozjpeg's default profile: progressive, trellis quantisation, optimised scans.
    jpeg_set_defaults(&cinfo);
    if (components == 4) {
        // Mirror the source's markers so that every viewer reads the samples the same way as
        // before: Adobe CMYK JPEGs are often stored inverted, and readers key off the marker.
        jpeg_set_colorspace(&cinfo, like && like->ycck ? JCS_YCCK : JCS_CMYK);
        cinfo.write_Adobe_marker = like ? like->adobe_marker : TRUE;
    }
    jpeg_set_quality(&cinfo, quality, TRUE);
    if (quality >= 90 && components == 3) {
        // No chroma subsampling at high quality: keeps coloured text and line art crisp.
        cinfo.comp_info[0].h_samp_factor = 1;
        cinfo.comp_info[0].v_samp_factor = 1;
    }
    jpeg_start_compress(&cinfo, TRUE);
    size_t stride = (size_t)width * components;
    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row = (JSAMPROW)(pixels + stride * cinfo.next_scanline);
        jpeg_write_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    *out_size = size;
    return out;
}

unsigned char* smol_jpeg_optimize(const unsigned char* data, size_t size, size_t* out_size) {
    struct jpeg_decompress_struct src;
    struct jpeg_compress_struct dst;
    ErrorManager err;
    unsigned char* volatile out = NULL;
    unsigned long out_len = 0;
    volatile int have_dst = 0;
    install_errors((j_common_ptr)&src, &err);
    dst.err = src.err;
    if (setjmp(err.jump)) {
        if (have_dst) jpeg_destroy_compress(&dst);
        jpeg_destroy_decompress(&src);
        free(out);
        return NULL;
    }
    jpeg_create_decompress(&src);
    jpeg_mem_src(&src, data, (unsigned long)size);
    jpeg_read_header(&src, TRUE);
    jvirt_barray_ptr* coefficients = jpeg_read_coefficients(&src);

    jpeg_create_compress(&dst);
    have_dst = 1;
    jpeg_copy_critical_parameters(&src, &dst);
    // Same markers as the source, so the colour interpretation can't change.
    dst.write_JFIF_header = src.saw_JFIF_marker;
    dst.write_Adobe_marker = src.saw_Adobe_marker;
    dst.optimize_coding = TRUE;
    jpeg_c_set_bool_param(&dst, JBOOLEAN_OPTIMIZE_SCANS, TRUE);
    jpeg_simple_progression(&dst);
    jpeg_mem_dest(&dst, (unsigned char**)&out, &out_len);
    jpeg_write_coefficients(&dst, coefficients);
    jpeg_finish_compress(&dst);
    jpeg_destroy_compress(&dst);
    jpeg_finish_decompress(&src);
    jpeg_destroy_decompress(&src);
    *out_size = out_len;
    return out;
}
