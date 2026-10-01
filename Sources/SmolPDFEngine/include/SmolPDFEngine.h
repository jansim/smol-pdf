#ifndef SMOLPDF_ENGINE_H
#define SMOLPDF_ENGINE_H

/*
 * The compression engine: rewrites a PDF with qpdf, re-encoding each image in the format that
 * suits it best and cleaning up the file structure. Plain C so Swift can call it directly.
 */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SmolOptions {
    /* Images ------------------------------------------------------------------------------- */
    /* Allow lossy changes to images: JPEG re-encoding and downsampling. Without it, images are
       only stored more efficiently (palette, true grayscale, better Flate, optimised JPEG). */
    int lossy_images;
    /* JPEG quality, 0 (smallest) ... 1 (best). Used with lossy_images. */
    double jpeg_quality;
    /* Downsample images shown above this resolution, in dpi. 0 keeps the resolution. */
    int max_resolution;
    /* Convert everything (text, vector graphics and images) to grayscale. */
    int grayscale;
    /* Store black-and-white scans (gray images that are almost only black and white) as 1-bit
       images. Used with lossy_images. */
    int monochrome_scans;

    /* Document ----------------------------------------------------------------------------- */
    int remove_metadata;    /* document info, XMP metadata */
    int remove_editing_data;/* private application data (e.g. Illustrator's), page thumbnails */
    int remove_annotations; /* annotations and form fields */
    int remove_bookmarks;
    int remove_attachments; /* embedded files */
    int remove_javascript;  /* document and annotation JavaScript actions */
} SmolOptions;

typedef struct SmolStats {
    long images;              /* image objects in the document */
    long images_changed;      /* ... of which were re-encoded */
    long images_downsampled;
    long long image_bytes_before; /* sizes of the changed images */
    long long image_bytes_after;
    long streams_recompressed;/* other streams stored with better compression */
    long duplicates_removed;  /* identical streams merged */
} SmolStats;

typedef enum SmolStatus {
    SMOL_OK = 0,
    SMOL_ERROR_OPEN,              /* not a readable PDF */
    SMOL_ERROR_PASSWORD_REQUIRED,
    SMOL_ERROR_WRONG_PASSWORD,
    SMOL_ERROR_WRITE,
    SMOL_ERROR_INTERNAL,
} SmolStatus;

/* Sets the options to lossless defaults. */
void smol_default_options(SmolOptions* options);

/* Compresses `input` into `output` (which must differ from `input`). `password` may be NULL.
   Encryption is kept as it was. `stats` may be NULL. On failure, a description is written to
   `message` (when not NULL). */
SmolStatus smol_compress(
    const char* input, const char* output, const char* password, const SmolOptions* options,
    SmolStats* stats, char* message, size_t message_size);

#ifdef __cplusplus
}
#endif

#endif
