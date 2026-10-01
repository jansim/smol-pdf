// smol_compress: loads a PDF with qpdf, optimises it, and writes it with object streams.

#include "Engine.hh"

#include <qpdf/Pl_Flate.hh>
#include <qpdf/QPDFExc.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>

#include <cstdio>
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

// Recompresses every stream other than images (content, fonts, ...) with libdeflate, keeping the
// original when that isn't smaller. Images were handled already.
void recompressStreams(QPDF& pdf, SmolStats& stats) {
    for (auto& obj : reachableObjects(pdf)) {
        if (!obj.isStream()) continue;
        QPDFObjectHandle dict = obj.getDict();
        if (dict.getKey("/Subtype").isNameAndEquals("/Image")) continue;
        // Cross-reference and object streams are rebuilt by the writer.
        if (dict.getKey("/Type").isNameAndEquals("/XRef") || dict.getKey("/Type").isNameAndEquals("/ObjStm")) continue;
        obj.setFilterOnWrite(false);
        if (hasLossyOrImageFilter(dict.getKey("/Filter"))) continue;
        try {
            auto decoded = obj.getStreamData(qpdf_dl_specialized);
            Bytes compressed = deflate(decoded->getBuffer(), decoded->getSize());
            if (compressed.size() + 8 < obj.getRawStreamData()->getSize()) {
                obj.replaceStreamData(compressed, QPDFObjectHandle::newName("/FlateDecode"), QPDFObjectHandle::newNull());
                stats.streams_recompressed++;
            }
        } catch (std::exception&) {
            // Undecodable: keep as is.
        }
    }
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
    SmolStats* stats_out, char* message, size_t message_size) {
    using namespace smol;
    SmolStats stats{};
    SmolOptions opts;
    if (options) opts = *options;
    else smol_default_options(&opts);

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

    try {
        removeContent(pdf, opts);
        QPDFPageDocumentHelper pages(pdf);
        for (auto& page : pages.getAllPages()) {
            // Larger inline images become image objects so they can be optimised too.
            // With grayscale all of them, so none keeps its colours.
            try {
                page.externalizeInlineImages(opts.grayscale ? 0 : 4096);
            } catch (std::exception&) {
            }
        }
        try {
            pages.removeUnreferencedResources();
        } catch (std::exception&) {
        }
        mergeDuplicateStreams(pdf, stats); // before images, so each is processed once
        optimizeImages(pdf, opts, stats);
        if (opts.grayscale) convertToGray(pdf);
        recompressStreams(pdf, stats);
        mergeDuplicateStreams(pdf, stats); // images that became identical
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
        writer.write();
    } catch (std::exception& e) {
        setMessage(message, message_size, e.what());
        std::remove(output);
        return SMOL_ERROR_WRITE;
    }

    if (stats_out) *stats_out = stats;
    return SMOL_OK;
}
