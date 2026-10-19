// Internal interfaces of the compression engine.
#pragma once

#include "SmolPDFEngine.h"

#include <qpdf/QPDF.hh>
#include <qpdf/QPDFObjGen.hh>
#include <qpdf/QPDFObjectHandle.hh>

#include <cstddef>
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace smol {

// Binary data. std::string because that's what qpdf's stream APIs take.
using Bytes = std::string;

// Engine.cc ---------------------------------------------------------------------------------------

// Indirect objects reachable from the trailer: what will be written. (QPDF::getAllObjects also
// returns objects that are no longer referenced.)
std::vector<QPDFObjectHandle> reachableObjects(QPDF& pdf);

// Codecs.cc ---------------------------------------------------------------------------------------

// zlib-format (FlateDecode) compression with libdeflate. Level 0 picks the best level that is
// still reasonably fast for the size; lower levels are for quick size estimates.
Bytes deflate(void const* data, size_t size, int level = 0);

// Applies PNG predictors, choosing the best filter per row (FlateDecode /Predictor 15).
Bytes pngPredict(uint8_t const* data, size_t rows, size_t row_bytes, size_t bytes_per_pixel);

// CCITT Group 4 (T.6) encoding of a 1-bit image, rows padded to whole bytes, MSB first. Sample
// value 0 is coded as black, so with /BlackIs1 false the decoded samples are bit-identical.
Bytes ccittG4(uint8_t const* bits, int width, int height);

// Lossless JBIG2 (generic region) encoding of the same kind of 1-bit image, as an embedded stream
// for /JBIG2Decode without globals.
Bytes jbig2Generic(uint8_t const* bits, int width, int height);

// Placement.cc ------------------------------------------------------------------------------------

struct Resolutions {
    // Lowest resolution (dpi) at which each image is drawn; the largest placement decides.
    std::map<QPDFObjGen, double> dpi;
    // Images whose placement could not be fully determined; never downsampled.
    std::set<QPDFObjGen> unknown;
};

Resolutions findImageResolutions(QPDF& pdf);

// Grayscale.cc ------------------------------------------------------------------------------------

// Converts the colours of text and vector graphics (not images) to gray.
void convertToGray(QPDF& pdf);

// Images.cc ---------------------------------------------------------------------------------------

void optimizeImages(QPDF& pdf, SmolOptions const& options, SmolStats& stats);

} // namespace smol
