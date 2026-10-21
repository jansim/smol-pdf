// smol_compress: loads a PDF with qpdf, optimises it, and writes it with object streams.

#include "Engine.hh"

#include <qpdf/Pl_Flate.hh>
#include <qpdf/QPDFExc.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <unordered_map>
#include <vector>

namespace smol {

std::vector<QPDFObjectHandle> reachableObjects(QPDF& pdf) {
    std::vector<QPDFObjectHandle> found;
    std::set<QPDFObjGen> seen;
    std::vector<QPDFObjectHandle> todo{pdf.getTrailer()};
    while (!todo.empty()) {
        QPDFObjectHandle obj = todo.back();
        todo.pop_back();
        auto visit = [&](QPDFObjectHandle item) {
            if (item.isIndirect()) {
                if (seen.insert(item.getObjGen()).second && !item.isNull()) {
                    found.push_back(item);
                    todo.push_back(item);
                }
            } else if (item.isArray() || item.isDictionary()) {
                todo.push_back(item);
            }
        };
        if (obj.isStream()) {
            visit(obj.getDict());
        } else if (obj.isArray()) {
            for (auto const& item : obj.getArrayAsVector()) visit(item);
        } else if (obj.isDictionary()) {
            for (auto const& [key, item] : obj.getDictAsMap()) visit(item);
        }
    }
    return found;
}

uint64_t streamCost(QPDFObjectHandle stream) {
    // Filtered data is typically a few times larger decoded; libdeflate's best level then takes
    // about 330 ns per byte.
    long long length = 0;
    QPDFObjectHandle dict = stream.getDict();
    dict.getKey("/Length").getValueAsInt(length);
    return uint64_t(std::max(length, 0LL)) * (dict.getKey("/Filter").isNull() ? 1 : 4) * 330;
}

namespace {

QPDFObjectHandle dictOf(QPDFObjectHandle obj) {
    if (obj.isStream()) return obj.getDict();
    if (obj.isDictionary()) return obj;
    return QPDFObjectHandle::newNull();
}

bool isJavaScriptAction(QPDFObjectHandle action) {
    return action.isDictionary() && action.getKey("/S").isNameAndEquals("/JavaScript");
}

// Removes what the options ask for. Everything removed here is simply no longer referenced, and
// QPDFWriter only writes objects that are still reachable.
void removeContent(QPDF& pdf, SmolOptions const& o) {
    QPDFObjectHandle root = pdf.getRoot();
    QPDFObjectHandle names = root.getKey("/Names");

    if (o.remove_metadata) {
        pdf.getTrailer().removeKey("/Info");
        root.removeKey("/Metadata");
    }
    if (o.remove_bookmarks) {
        root.removeKey("/Outlines");
        if (root.getKey("/PageMode").isNameAndEquals("/UseOutlines")) root.removeKey("/PageMode");
    }
    if (o.remove_annotations) {
        root.removeKey("/AcroForm");
    }
    if (o.remove_attachments) {
        if (names.isDictionary()) names.removeKey("/EmbeddedFiles");
        root.removeKey("/Collection");
        if (root.getKey("/PageMode").isNameAndEquals("/UseAttachments")) root.removeKey("/PageMode");
    }
    if (o.remove_javascript) {
        if (names.isDictionary()) names.removeKey("/JavaScript");
        if (isJavaScriptAction(root.getKey("/OpenAction"))) root.removeKey("/OpenAction");
    }

    for (auto& page : QPDFPageDocumentHelper(pdf).getAllPages()) {
        QPDFObjectHandle dict = page.getObjectHandle();
        if (o.remove_annotations) {
            dict.removeKey("/Annots");
        } else if (o.remove_attachments) {
            QPDFObjectHandle annots = dict.getKey("/Annots");
            if (annots.isArray()) {
                for (int i = annots.getArrayNItems() - 1; i >= 0; --i) {
                    if (annots.getArrayItem(i).getKey("/Subtype").isNameAndEquals("/FileAttachment")) {
                        annots.eraseItem(i);
                    }
                }
            }
        }
        if (o.remove_editing_data) dict.removeKey("/Thumb");
    }

    if (o.remove_metadata || o.remove_editing_data || o.remove_javascript || o.remove_attachments) {
        for (auto& obj : reachableObjects(pdf)) {
            QPDFObjectHandle dict = dictOf(obj);
            if (dict.isNull()) continue;
            if (o.remove_metadata) dict.removeKey("/Metadata");
            if (o.remove_editing_data) dict.removeKey("/PieceInfo");
            if (o.remove_attachments) dict.removeKey("/AF");
            if (o.remove_javascript) {
                dict.removeKey("/AA");
                if (isJavaScriptAction(dict.getKey("/A"))) dict.removeKey("/A");
                if (isJavaScriptAction(dict.getKey("/Next"))) dict.removeKey("/Next");
            }
        }
    }
}

std::string rawData(QPDFObjectHandle stream) {
    auto buffer = stream.getRawStreamData();
    return std::string(reinterpret_cast<char const*>(buffer->getBuffer()), buffer->getSize());
}

bool hasLossyOrImageFilter(QPDFObjectHandle filter) {
    std::vector<QPDFObjectHandle> filters;
    if (filter.isArray()) filters = filter.getArrayAsVector();
    else filters.push_back(filter);
    for (auto& f : filters) {
        if (!f.isName()) continue;
        std::string n = f.getName();
        if (n == "/DCTDecode" || n == "/JPXDecode" || n == "/JBIG2Decode" || n == "/CCITTFaxDecode" || n == "/Crypt") {
            return true;
        }
    }
    return false;
}

// Whether recompressStreams handles a stream: anything but images (handled already), what the
// writer makes, and the document's XMP metadata, which the writer stores uncompressed so that other
// tools can read it and PDF/A files stay valid.
bool isRecompressible(QPDFObjectHandle obj) {
    if (!obj.isStream() || obj.isRootMetadata()) return false;
    QPDFObjectHandle dict = obj.getDict();
    return !dict.getKey("/Subtype").isNameAndEquals("/Image") && !dict.getKey("/Type").isNameAndEquals("/XRef") &&
           !dict.getKey("/Type").isNameAndEquals("/ObjStm");
}

// Compresses one stream's data on a worker thread.
class Recompression: public Task {
  public:
    Recompression(QPDFObjectHandle stream, Bytes decoded, size_t original, uint64_t cost, SmolStats& stats,
                  Progress& progress) :
        stream_(std::move(stream)),
        decoded_(std::move(decoded)),
        original_(original),
        memory_(decoded_.size() * 2),
        cost_(cost),
        stats_(stats),
        progress_(progress) {}

    size_t memory() const override { return memory_; }

    void run(Progress& progress) override {
        progress.check();
        compressed_ = deflate(decoded_.data(), decoded_.size());
        Bytes().swap(decoded_);
    }

    void apply(bool failed) override {
        if (!failed && compressed_.size() + 8 < original_) {
            stream_.replaceStreamData(compressed_, QPDFObjectHandle::newName("/FlateDecode"), QPDFObjectHandle::newNull());
            stats_.streams_recompressed++;
        }
        progress_.advance(cost_);
    }

  private:
    QPDFObjectHandle stream_;
    Bytes decoded_, compressed_;
    size_t original_, memory_;
    uint64_t cost_;
    SmolStats& stats_;
    Progress& progress_;
};

// Recompresses every stream other than images (content, fonts, ...) with libdeflate, keeping the
// original when that isn't smaller.
void recompressStreams(QPDF& pdf, SmolStats& stats, Progress& progress) {
    auto objects = reachableObjects(pdf);
    size_t next = 0;
    runTasks(
        [&]() -> std::unique_ptr<Task> {
            while (next < objects.size()) {
                QPDFObjectHandle obj = objects[next++];
                if (!isRecompressible(obj)) continue;
                obj.setFilterOnWrite(false);
                uint64_t cost = streamCost(obj);
                if (!hasLossyOrImageFilter(obj.getDict().getKey("/Filter"))) {
                    try {
                        auto decoded = obj.getStreamData(qpdf_dl_specialized);
                        size_t original = obj.getRawStreamData()->getSize();
                        Bytes data(reinterpret_cast<char const*>(decoded->getBuffer()), decoded->getSize());
                        return std::make_unique<Recompression>(obj, std::move(data), original, cost, stats, progress);
                    } catch (std::exception&) {
                        // Undecodable: keep as is.
                    }
                }
                progress.advance(cost);
            }
            return nullptr;
        },
        progress);
}

void replaceReferences(QPDFObjectHandle obj, std::map<QPDFObjGen, QPDFObjectHandle> const& to, int depth) {
    if (depth > 64) return;
    auto visit = [&](QPDFObjectHandle item, auto const& replace) {
        if (item.isIndirect()) {
            auto found = to.find(item.getObjGen());
            if (found != to.end()) replace(found->second);
        } else if (item.isArray() || item.isDictionary()) {
            replaceReferences(item, to, depth + 1);
        }
    };
    if (obj.isStream()) {
        replaceReferences(obj.getDict(), to, depth + 1);
    } else if (obj.isArray()) {
        int n = obj.getArrayNItems();
        for (int i = 0; i < n; ++i) {
            visit(obj.getArrayItem(i), [&](QPDFObjectHandle const& r) { obj.setArrayItem(i, r); });
        }
    } else if (obj.isDictionary()) {
        for (auto const& key : obj.getKeys()) {
            visit(obj.getKey(key), [&](QPDFObjectHandle const& r) { obj.replaceKey(key, r); });
        }
    }
}

// Makes identical streams (same dictionary and data) share one object: fonts embedded once per
// page, the same logo on every page, ...
void mergeDuplicateStreams(QPDF& pdf, SmolStats& stats) {
    std::unordered_map<std::string, std::vector<QPDFObjectHandle>> by_key;
    std::map<QPDFObjGen, QPDFObjectHandle> replacements;
    for (auto& obj : reachableObjects(pdf)) {
        if (!obj.isStream()) continue;
        QPDFObjectHandle dict = obj.getDict();
        if (dict.getKey("/Type").isNameAndEquals("/XRef") || dict.getKey("/Type").isNameAndEquals("/ObjStm")) continue;
        QPDFObjectHandle copy = dict.shallowCopy();
        copy.removeKey("/Length");
        std::string data;
        try {
            data = rawData(obj);
        } catch (std::exception&) {
            continue;
        }
        std::string key = copy.unparse();
        key += '\n';
        key += std::to_string(data.size());
        key += ':';
        key += std::to_string(std::hash<std::string>()(data));
        auto& same = by_key[key];
        bool merged = false;
        for (auto& other : same) {
            if (rawData(other) == data) {
                replacements[obj.getObjGen()] = other;
                merged = true;
                break;
            }
        }
        if (!merged) same.push_back(obj);
    }
    if (replacements.empty()) return;
    stats.duplicates_removed += long(replacements.size());
    for (auto& obj : reachableObjects(pdf)) replaceReferences(obj, replacements, 0);
    replaceReferences(pdf.getTrailer(), replacements, 0);
}

// Tells `progress` about all the work ahead, so that it moves evenly; returns the part that is
// writing the file.
uint64_t plan(QPDF& pdf, std::vector<QPDFPageObjectHelper>& pages, SmolOptions const& o, Progress& progress) {
    auto objects = reachableObjects(pdf);
    uint64_t write = objects.size() * 1000, work = 0;
    bool images = false;
    for (auto& obj : objects) {
        if (!obj.isStream()) continue;
        long long length = 0;
        obj.getDict().getKey("/Length").getValueAsInt(length);
        write += uint64_t(std::max(length, 0LL)) * 2;
        if (obj.getDict().getKey("/Subtype").isNameAndEquals("/Image")) {
            images = true;
            work += imageCost(obj, o);
        } else if (isRecompressible(obj)) {
            work += streamCost(obj);
        }
    }
    // Page content is parsed to externalise inline images, to drop unused resources, to find image
    // resolutions (only needed for downsampling) and to convert colours.
    uint64_t content = 0;
    for (auto& page : pages) content += contentCost(page.getObjectHandle());
    work += content * (2 + (o.lossy_images && images ? 1 : 0) + (o.grayscale ? 1 : 0));
    progress.expect(work + write);
    return write;
}

// With SMOL_DEBUG, prints how long each step took.
class StepTimer {
  public:
    void operator()(char const* step) {
        if (!on_) return;
        auto now = std::chrono::steady_clock::now();
        std::fprintf(stderr, "step %-20s %.2fs\n", step, std::chrono::duration<double>(now - last_).count());
        last_ = now;
    }

  private:
    bool on_ = std::getenv("SMOL_DEBUG") != nullptr;
    std::chrono::steady_clock::time_point last_ = std::chrono::steady_clock::now();
};

void setMessage(char* message, size_t size, std::string const& text) {
    if (!message || !size) return;
    std::snprintf(message, size, "%s", text.c_str());
}

} // namespace
} // namespace smol

extern "C" void smol_default_options(SmolOptions* options) {
    std::memset(options, 0, sizeof(*options));
    options->jpeg_quality = 0.75;
}

extern "C" SmolStatus smol_compress(
    char const* input, char const* output, char const* password, SmolOptions const* options,
    SmolProgressCallback progress_callback, void* progress_context, SmolStats* stats_out, char* message,
    size_t message_size) {
    using namespace smol;
    SmolStats stats{};
    SmolOptions opts;
    if (options) opts = *options;
    else smol_default_options(&opts);
    Progress progress(progress_callback, progress_context);
    StepTimer step;

    QPDF pdf;
    pdf.setSuppressWarnings(true);
    pdf.setAttemptRecovery(true);
    try {
        pdf.processFile(input, password && *password ? password : nullptr);
    } catch (QPDFExc& e) {
        setMessage(message, message_size, e.what());
        if (e.getErrorCode() == qpdf_e_password) {
            return password && *password ? SMOL_ERROR_WRONG_PASSWORD : SMOL_ERROR_PASSWORD_REQUIRED;
        }
        return SMOL_ERROR_OPEN;
    } catch (std::exception& e) {
        setMessage(message, message_size, e.what());
        return SMOL_ERROR_OPEN;
    }
    step("open");

    uint64_t write_cost = 0;
    try {
        progress.report(true);
        removeContent(pdf, opts);
        std::vector<QPDFPageObjectHelper> pages = QPDFPageDocumentHelper(pdf).getAllPages();
        write_cost = plan(pdf, pages, opts, progress);
        step("remove and plan");
        for (auto& page : pages) {
            uint64_t cost = contentCost(page.getObjectHandle());
            // Larger inline images become image objects so they can be optimised too.
            // With grayscale all of them, so none keeps its colours.
            try {
                page.externalizeInlineImages(opts.grayscale ? 0 : 4096);
            } catch (std::exception&) {
            }
            progress.advance(cost);
            progress.report();
        }
        for (auto& page : pages) {
            uint64_t cost = contentCost(page.getObjectHandle());
            try {
                page.removeUnreferencedResources();
            } catch (std::exception&) {
            }
            progress.advance(cost);
            progress.report();
        }
        step("tidy pages");
        mergeDuplicateStreams(pdf, stats); // before images, so each is processed once
        progress.report();
        step("merge duplicates");
        optimizeImages(pdf, opts, stats, progress);
        step("images");
        if (opts.grayscale) {
            convertToGray(pdf, progress);
            step("grayscale");
        }
        recompressStreams(pdf, stats, progress);
        step("streams");
        mergeDuplicateStreams(pdf, stats); // images that became identical
        progress.report();
        step("merge duplicates");
    } catch (Cancelled&) {
        setMessage(message, message_size, "cancelled");
        return SMOL_CANCELLED;
    } catch (std::exception& e) {
        setMessage(message, message_size, e.what());
        return SMOL_ERROR_INTERNAL;
    }

    try {
        // Only standard trailer keys, and a /Size for the writer to fill in: damaged files can have
        // misspelled keys, which would otherwise be copied and leave the output without a /Size.
        QPDFObjectHandle trailer = pdf.getTrailer();
        for (auto const& key : trailer.getKeys()) {
            if (key != "/Root" && key != "/Info" && key != "/ID" && key != "/Encrypt") trailer.removeKey(key);
        }
        trailer.replaceKey("/Size", QPDFObjectHandle::newInteger(0));

        Pl_Flate::setCompressionLevel(9);
        QPDFWriter writer(pdf, output);
        writer.setObjectStreamMode(qpdf_o_generate);
        writer.setCompressStreams(true);
        writer.setDecodeLevel(qpdf_dl_generalized);
        writer.setPreserveEncryption(true);
        uint64_t written = 0;
        writer.registerProgressReporter(std::make_shared<QPDFWriter::FunctionProgressReporter>([&](int percent) {
            uint64_t now = write_cost * uint64_t(std::clamp(percent, 0, 100)) / 100;
            if (now > written) progress.advance(now - written);
            written = std::max(written, now);
            progress.report();
        }));
        writer.write();
        step("write");
    } catch (Cancelled&) {
        setMessage(message, message_size, "cancelled");
        std::remove(output);
        return SMOL_CANCELLED;
    } catch (std::exception& e) {
        setMessage(message, message_size, e.what());
        std::remove(output);
        return SMOL_ERROR_WRITE;
    }

    progress.finish();
    if (stats_out) *stats_out = stats;
    return SMOL_OK;
}
