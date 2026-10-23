// Internal interfaces of the compression engine.
#pragma once

#include "SmolPDFEngine.h"

#include <qpdf/QPDF.hh>
#include <qpdf/QPDFObjGen.hh>
#include <qpdf/QPDFObjectHandle.hh>

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace smol {

// Binary data. std::string because that's what qpdf's stream APIs take.
using Bytes = std::string;

// Parallel.cc -------------------------------------------------------------------------------------

// Thrown when the caller cancels. Not a std::exception, so that the code that skips over damaged
// objects doesn't catch it.
struct Cancelled {};

// Progress through one smol_compress call, measured in estimated costs (roughly nanoseconds of
// work), and whether to stop.
class Progress {
  public:
    Progress(SmolProgressCallback callback, void* context) :
        callback_(callback),
        context_(context) {}

    // Adds work that is still to come. Calling thread only, before that work starts.
    void expect(uint64_t cost) { total_ += cost; }
    // Marks work as done. Any thread.
    void advance(uint64_t cost) { done_.fetch_add(cost, std::memory_order_relaxed); }
    // Tells the callback, at most ten times a second unless `force`, and throws Cancelled when it
    // asks to stop. Calling thread only.
    void report(bool force = false);
    // Reports that all is done; too late to cancel.
    void finish() {
        if (callback_) callback_(context_, 1);
    }
    // Whether work should stop (cancelled, or failed elsewhere). Any thread.
    bool stopping() const { return stop_.load(std::memory_order_relaxed); }
    void stop() { stop_.store(true, std::memory_order_relaxed); }
    // Throws Cancelled when stopping; for worker threads, between steps.
    void check() const {
        if (stopping()) throw Cancelled();
    }

  private:
    SmolProgressCallback callback_;
    void* context_;
    uint64_t total_ = 0;
    std::atomic<uint64_t> done_{0};
    std::atomic<bool> stop_{false};
    double reported_ = 0;
    std::chrono::steady_clock::time_point last_{};
};

// A piece of work for the worker threads. qpdf objects are not thread-safe, so whatever needs them
// happens on the calling thread: before the task is handed to runTasks, and in apply(). run() only
// computes, and must not use qpdf objects (copying a QPDFObjectHandle is fine).
class Task {
  public:
    virtual ~Task() = default;
    // Bytes the task holds until it is applied, to keep memory use in bounds.
    virtual size_t memory() const = 0;
    // On a worker thread. May throw (Cancelled, or anything else, which fails the task).
    virtual void run(Progress& progress) = 0;
    // On the calling thread, once run() returned or threw (`failed`).
    virtual void apply(bool failed) = 0;
};

// Runs the tasks `next` makes (on the calling thread, until it returns null) on worker threads,
// one per core, and applies each as soon as it is done. Reports progress meanwhile. Workers are
// shared by all smol_compress calls in the process; SMOL_THREADS sets their number.
void runTasks(std::function<std::unique_ptr<Task>()> const& next, Progress& progress);

// Engine.cc ---------------------------------------------------------------------------------------

// Indirect objects reachable from the trailer: what will be written. (QPDF::getAllObjects also
// returns objects that are no longer referenced.) With `progress`, lets the caller cancel meanwhile.
std::vector<QPDFObjectHandle> reachableObjects(QPDF& pdf, Progress* progress = nullptr);

// Estimated cost of decoding a stream's raw data and compressing it again.
uint64_t streamCost(QPDFObjectHandle stream);

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

Resolutions findImageResolutions(QPDF& pdf, Progress& progress);

// Estimated cost of parsing a page's content (once).
uint64_t contentCost(QPDFObjectHandle page);

// Grayscale.cc ------------------------------------------------------------------------------------

// Converts the colours of text and vector graphics (not images) to gray.
void convertToGray(QPDF& pdf, Progress& progress);

// Images.cc ---------------------------------------------------------------------------------------

// Estimated cost of optimising an image.
uint64_t imageCost(QPDFObjectHandle image, SmolOptions const& options);

void optimizeImages(QPDF& pdf, SmolOptions const& options, SmolStats& stats, Progress& progress);

} // namespace smol
