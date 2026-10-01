// Re-encodes each image in the format that suits it best.
//
// For every image a set of candidate encodings is made (lossless ones always, lossy ones when
// allowed) and the smallest is kept, including the original. Lossless forms are preferred when
// they are nearly as small, since they stay sharp:
//
//   - Flate with PNG predictors, tuned per row        (any image)
//   - fewer bits per sample, a palette, true gray      (when that is exact)
//   - CCITT Group 4                                    (1-bit images and masks)
//   - optimised Huffman tables / progressive JPEG      (JPEGs, without touching pixels)
//   - JPEG at the chosen quality                       (photographic content, lossy)
//   - downsampling to the target resolution            (lossy)
//   - 1-bit conversion of black-and-white scans        (lossy, optional)

#include "Engine.hh"
#include "jpeg_codec.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unordered_map>
#include <vector>

namespace smol {

namespace {

// Images are processed only up to this many pixels (larger ones are left alone).
constexpr unsigned long long max_pixels = 200ULL * 1000 * 1000;
// Downsample only when the image is at least this much sharper than the target.
constexpr double downsample_threshold = 1.2;
// A lossy candidate must be this much smaller than the best lossless one to win.
constexpr double lossless_preference = 1.10;
// Flate candidates are compared using a fast compression level and only the winner is compressed
// at the best level; this is roughly how much that gains.
constexpr int estimate_level = 6;
constexpr double estimate_gain = 0.96;

enum class Family { Gray, RGB, CMYK, Other };

// Set SMOL_DEBUG to trace the decisions for each image on stderr.
bool debugging() {
    static bool const on = std::getenv("SMOL_DEBUG") != nullptr;
    return on;
}

double now() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

struct ColorSpace {
    QPDFObjectHandle object = QPDFObjectHandle::newNull(); // as in the image dictionary
    bool indexed = false;
    Family family = Family::Other; // of the colour values (the base for Indexed)
    int n = 0;                     // samples per pixel (1 for Indexed)
    QPDFObjectHandle base = QPDFObjectHandle::newNull(); // colour space of the colour values
    int base_n = 0;                // components of a colour value
    int hival = 0;                 // Indexed: highest index
    std::string palette;           // Indexed: (hival + 1) * base_n bytes
};

bool parseColorSpace(QPDFObjectHandle cs, ColorSpace& out, bool allow_indexed = true) {
    out.object = cs;
    if (cs.isName()) {
        std::string name = cs.getName();
        if (name == "/DeviceGray") out.family = Family::Gray, out.n = 1;
        else if (name == "/DeviceRGB") out.family = Family::RGB, out.n = 3;
        else if (name == "/DeviceCMYK") out.family = Family::CMYK, out.n = 4;
        else return false;
    } else if (cs.isArray() && cs.getArrayNItems() >= 1 && cs.getArrayItem(0).isName()) {
        std::string name = cs.getArrayItem(0).getName();
        QPDFObjectHandle arg = cs.getArrayNItems() >= 2 ? cs.getArrayItem(1) : QPDFObjectHandle::newNull();
        if (name == "/ICCBased") {
            if (!arg.isStream()) return false;
            int n = 0;
            if (!arg.getDict().getKey("/N").getValueAsInt(n)) return false;
            if (n == 1) out.family = Family::Gray;
            else if (n == 3) out.family = Family::RGB;
            else if (n == 4) out.family = Family::CMYK;
            else return false;
            out.n = n;
        } else if (name == "/CalGray") {
            out.family = Family::Gray, out.n = 1;
        } else if (name == "/CalRGB") {
            out.family = Family::RGB, out.n = 3;
        } else if (name == "/Lab") {
            out.family = Family::Other, out.n = 3;
        } else if (name == "/Separation") {
            out.family = Family::Other, out.n = 1;
        } else if (name == "/DeviceN") {
            if (!arg.isArray() || arg.getArrayNItems() < 1) return false;
            out.family = Family::Other, out.n = arg.getArrayNItems();
        } else if (name == "/Indexed" && allow_indexed) {
            if (cs.getArrayNItems() != 4) return false;
            ColorSpace base;
            if (!parseColorSpace(arg, base, false)) return false;
            int hival = 0;
            if (!cs.getArrayItem(2).getValueAsInt(hival) || hival < 0 || hival > 255) return false;
            QPDFObjectHandle lookup = cs.getArrayItem(3);
            std::string table;
            if (lookup.isString()) table = lookup.getStringValue();
            else if (lookup.isStream()) {
                auto buffer = lookup.getStreamData(qpdf_dl_specialized);
                table.assign(reinterpret_cast<char const*>(buffer->getBuffer()), buffer->getSize());
            } else return false;
            size_t need = size_t(hival + 1) * size_t(base.n);
            if (table.size() < need) return false;
            table.resize(need);
            out.indexed = true;
            out.family = base.family;
            out.n = 1;
            out.base = base.object;
            out.base_n = base.n;
            out.hival = hival;
            out.palette = std::move(table);
            return true;
        } else {
            return false;
        }
    } else {
        return false;
    }
    out.base = out.object;
    out.base_n = out.n;
    return out.n > 0 && out.n <= 32;
}

// Interleaved samples, 8 bits each (palette indices for Indexed images).
struct Raster {
    int w = 0, h = 0, n = 0;
    std::vector<uint8_t> px;
    size_t size() const { return px.size(); }
};

size_t rowBytes(int w, int n, int bpc) {
    return (size_t(w) * size_t(n) * size_t(bpc) + 7) / 8;
}

// Unpacks samples to 8 bits. With `scale`, values are stretched to 0-255 (colour values);
// without, they are kept (palette indices). 16-bit samples keep their high byte.
Raster unpack(Bytes const& packed, int w, int h, int n, int bpc, bool scale) {
    Raster r{w, h, n, std::vector<uint8_t>(size_t(w) * h * n)};
    size_t stride = rowBytes(w, n, bpc);
    size_t per_row = size_t(w) * n;
    int max = (1 << std::min(bpc, 8)) - 1;
    for (int y = 0; y < h; ++y) {
        auto const* row = reinterpret_cast<uint8_t const*>(packed.data()) + stride * size_t(y);
        uint8_t* out = r.px.data() + per_row * size_t(y);
        if (bpc == 8) {
            std::memcpy(out, row, per_row);
        } else if (bpc == 16) {
            for (size_t i = 0; i < per_row; ++i) out[i] = row[2 * i];
        } else {
            for (size_t i = 0; i < per_row; ++i) {
                size_t bit = i * size_t(bpc);
                int v = (row[bit >> 3] >> (8 - bpc - int(bit & 7))) & max;
                out[i] = uint8_t(scale ? v * 255 / max : v);
            }
        }
    }
    return r;
}

// Packs 8-bit values that already fit in `bpc` bits.
Bytes pack(std::vector<uint8_t> const& px, int w, int h, int n, int bpc) {
    if (bpc == 8) return Bytes(px.begin(), px.end());
    size_t stride = rowBytes(w, n, bpc);
    Bytes out(stride * size_t(h), '\0');
    size_t per_row = size_t(w) * n;
    for (int y = 0; y < h; ++y) {
        uint8_t const* in = px.data() + per_row * size_t(y);
        auto* row = reinterpret_cast<uint8_t*>(out.data()) + stride * size_t(y);
        for (size_t i = 0; i < per_row; ++i) {
            size_t bit = i * size_t(bpc);
            row[bit >> 3] |= uint8_t(in[i] << (8 - bpc - int(bit & 7)));
        }
    }
    return out;
}

// Area-averaging downscale.
Raster downscale(Raster const& src, int nw, int nh) {
    struct Tap {
        int index;
        float weight;
    };
    auto taps = [](int from, int to) {
        std::vector<std::vector<Tap>> out(static_cast<size_t>(to));
        double ratio = double(from) / to;
        for (int i = 0; i < to; ++i) {
            double start = i * ratio, end = (i + 1) * ratio;
            for (int s = int(start); s < std::min(from, int(std::ceil(end))); ++s) {
                double weight = std::min(end, s + 1.0) - std::max(start, double(s));
                if (weight > 1e-6) out[size_t(i)].push_back({s, float(weight / ratio)});
            }
        }
        return out;
    };
    auto xs = taps(src.w, nw);
    auto ys = taps(src.h, nh);
    int n = src.n;
    Raster out{nw, nh, n, std::vector<uint8_t>(size_t(nw) * nh * n)};
    std::vector<float> row(size_t(nw) * n), acc(size_t(nw) * n);
    int cached = -1;
    auto horizontal = [&](int sy) {
        if (cached == sy) return;
        uint8_t const* in = src.px.data() + size_t(sy) * src.w * n;
        for (int x = 0; x < nw; ++x) {
            for (int c = 0; c < n; ++c) {
                float v = 0;
                for (auto const& t : xs[size_t(x)]) v += t.weight * in[size_t(t.index) * n + c];
                row[size_t(x) * n + c] = v;
            }
        }
        cached = sy;
    };
    for (int y = 0; y < nh; ++y) {
        std::fill(acc.begin(), acc.end(), 0.0f);
        for (auto const& t : ys[size_t(y)]) {
            horizontal(t.index);
            for (size_t i = 0; i < acc.size(); ++i) acc[i] += t.weight * row[i];
        }
        uint8_t* o = out.px.data() + size_t(y) * nw * n;
        for (size_t i = 0; i < acc.size(); ++i) o[i] = uint8_t(std::clamp(std::lround(acc[i]), 0L, 255L));
    }
    return out;
}

// Counts distinct colours up to `limit` + 1, building a palette when there are at most `limit`.
struct PaletteResult {
    bool fits = false;
    std::string palette;         // n bytes per entry
    std::vector<uint8_t> indices;
    int count = 0;
};

PaletteResult makePalette(Raster const& r, int limit = 256) {
    PaletteResult result;
    if (r.n > 4) return result;
    std::unordered_map<uint32_t, uint8_t> seen;
    seen.reserve(512);
    result.indices.resize(size_t(r.w) * r.h);
    size_t pixels = size_t(r.w) * r.h;
    uint32_t last_key = ~0u;
    uint8_t last_index = 0;
    for (size_t i = 0; i < pixels; ++i) {
        uint8_t const* p = r.px.data() + i * size_t(r.n);
        uint32_t key = 0;
        for (int c = 0; c < r.n; ++c) key = (key << 8) | p[c];
        if (key != last_key) {
            auto found = seen.find(key);
            if (found == seen.end()) {
                if (int(seen.size()) >= limit) return PaletteResult{false, {}, {}, limit + 1};
                found = seen.emplace(key, uint8_t(seen.size())).first;
                result.palette.append(reinterpret_cast<char const*>(p), size_t(r.n));
            }
            last_key = key;
            last_index = found->second;
        }
        result.indices[i] = last_index;
    }
    result.fits = true;
    result.count = int(seen.size());
    return result;
}

int bitsForCount(int count) {
    return count <= 2 ? 1 : count <= 4 ? 2 : count <= 16 ? 4 : 8;
}

uint8_t luma(uint8_t r, uint8_t g, uint8_t b) {
    return uint8_t((299 * r + 587 * g + 114 * b + 500) / 1000);
}

uint8_t cmykToGray(uint8_t c, uint8_t m, uint8_t y, uint8_t k) {
    int ink = (30 * c + 59 * m + 11 * y) / 100 + k;
    return uint8_t(255 - std::min(255, ink));
}

// Converts colour values (`n` per entry) of the given family to gray.
std::vector<uint8_t> toGray(uint8_t const* values, size_t count, Family family) {
    std::vector<uint8_t> out(count);
    for (size_t i = 0; i < count; ++i) {
        uint8_t const* p = values + i * (family == Family::RGB ? 3 : 4);
        out[i] = family == Family::RGB ? luma(p[0], p[1], p[2]) : cmykToGray(p[0], p[1], p[2], p[3]);
    }
    return out;
}

enum class Grayness { Color, Near, Exact };

// Whether RGB colour values are gray, exactly or within JPEG-like noise.
Grayness grayness(uint8_t const* rgb, size_t count) {
    bool exact = true;
    unsigned long long total = 0;
    for (size_t i = 0; i < count; ++i) {
        uint8_t const* p = rgb + 3 * i;
        int hi = std::max({p[0], p[1], p[2]}), lo = std::min({p[0], p[1], p[2]});
        int spread = hi - lo;
        if (spread > 24) return Grayness::Color;
        exact = exact && spread == 0;
        total += unsigned(spread);
    }
    if (exact) return Grayness::Exact;
    return count && double(total) / double(count) <= 1.5 ? Grayness::Near : Grayness::Color;
}

QPDFObjectHandle name(char const* n) {
    return QPDFObjectHandle::newName(n);
}

QPDFObjectHandle intObj(long long v) {
    return QPDFObjectHandle::newInteger(v);
}

struct Candidate {
    Bytes data;
    QPDFObjectHandle filter = QPDFObjectHandle::newNull();      // null for none
    QPDFObjectHandle parms = QPDFObjectHandle::newNull();       // null for none
    int w = 0, h = 0, bpc = 0;
    QPDFObjectHandle color_space = QPDFObjectHandle::newNull(); // null: keep
    bool drop_decode = false;
    bool lossy = false;
    bool resampled = false;
    Bytes pending;     // Flate input, compressed for real if this candidate wins
    std::string label; // for SMOL_DEBUG
};

// Everything known about one image while it is being optimised.
class Job {
  public:
    Job(QPDFObjectHandle image, SmolOptions const& options, bool is_smask) :
        image_(std::move(image)),
        dict_(image_.getDict()),
        options_(options),
        is_smask_(is_smask) {}

    bool prepare();
    void run(double dpi, bool is_smask, bool has_matte, SmolStats& stats);

  private:
    void addFlate(Bytes const& samples, int w, int h, int n, int bpc, Candidate base, bool predictor);
    void addFromRaster(Raster const& r, ColorSpace const& cs, bool keep_decode, bool lossy, bool resampled,
                       bool reductions_only = false);
    QPDFObjectHandle indexedSpace(QPDFObjectHandle base, int base_n, std::string const& palette) const;

    QPDFObjectHandle image_;
    QPDFObjectHandle dict_;
    SmolOptions const& options_;
    int w_ = 0, h_ = 0, bpc_ = 0;
    bool mask_ = false;
    ColorSpace cs_;
    bool default_decode_ = true;
    bool color_key_ = false;
    bool is_smask_ = false; // soft masks must stay DeviceGray
    bool dct_ = false;
    SmolJPEGInfo jpeg_{};
    Bytes raw_;
    Bytes samples_; // decoded, packed samples (not for JPEGs)
    std::vector<Candidate> candidates_;
};

bool isDefaultDecode(QPDFObjectHandle decode, int n, bool indexed, int bpc) {
    if (decode.isNull()) return true;
    if (!decode.isArray() || decode.getArrayNItems() != 2 * n) return false;
    for (int i = 0; i < n; ++i) {
        double lo = 0, hi = 0;
        if (!decode.getArrayItem(2 * i).getValueAsNumber(lo) ||
            !decode.getArrayItem(2 * i + 1).getValueAsNumber(hi)) {
            return false;
        }
        double want_hi = indexed ? double((1 << bpc) - 1) : 1.0;
        if (lo != 0 || hi != want_hi) return false;
    }
    return true;
}

std::vector<std::string> filterNames(QPDFObjectHandle filter, bool& ok) {
    std::vector<std::string> names;
    ok = true;
    if (filter.isName()) {
        names.push_back(filter.getName());
    } else if (filter.isArray()) {
        for (int i = 0; i < filter.getArrayNItems(); ++i) {
            QPDFObjectHandle f = filter.getArrayItem(i);
            if (!f.isName()) ok = false;
            else names.push_back(f.getName());
        }
    } else if (!filter.isNull()) {
        ok = false;
    }
    return names;
}

bool Job::prepare() {
    if (!dict_.getKey("/Width").getValueAsInt(w_) || !dict_.getKey("/Height").getValueAsInt(h_)) return false;
    if (w_ <= 0 || h_ <= 0 || (unsigned long long)w_ * h_ > max_pixels) return false;
    mask_ = dict_.getKey("/ImageMask").isBool() && dict_.getKey("/ImageMask").getBoolValue();

    bool ok = true;
    auto filters = filterNames(dict_.getKey("/Filter"), ok);
    if (!ok) return false;
    for (auto const& f : filters) {
        // Already efficient or not decodable here.
        if (f == "/JPXDecode" || f == "/JBIG2Decode" || f == "/CCITTFaxDecode" || f == "/Crypt") return false;
    }
    dct_ = filters.size() == 1 && filters[0] == "/DCTDecode";
    if (!dct_ && std::find(filters.begin(), filters.end(), "/DCTDecode") != filters.end()) return false;

    auto raw = image_.getRawStreamData();
    raw_.assign(reinterpret_cast<char const*>(raw->getBuffer()), raw->getSize());

    if (mask_) {
        bpc_ = 1;
        cs_.n = 1;
        if (dct_) return false;
    } else {
        if (!parseColorSpace(dict_.getKey("/ColorSpace"), cs_)) return false;
        if (dct_) {
            bpc_ = 8;
        } else if (!dict_.getKey("/BitsPerComponent").getValueAsInt(bpc_)) {
            return false;
        }
        if (bpc_ != 1 && bpc_ != 2 && bpc_ != 4 && bpc_ != 8 && bpc_ != 16) return false;
        if (cs_.indexed && bpc_ == 16) return false;
        default_decode_ = isDefaultDecode(dict_.getKey("/Decode"), cs_.n, cs_.indexed, bpc_);
        color_key_ = dict_.getKey("/Mask").isArray();
    }

    if (dct_) {
        QPDFObjectHandle parms = dict_.getKey("/DecodeParms");
        if (parms.isArray() && parms.getArrayNItems() == 1) parms = parms.getArrayItem(0);
        if (parms.isDictionary() && parms.hasKey("/ColorTransform")) return false;
        if (cs_.indexed) return false;
        auto const* data = reinterpret_cast<unsigned char const*>(raw_.data());
        if (!smol_jpeg_info(data, raw_.size(), &jpeg_)) return false;
        if (jpeg_.width != w_ || jpeg_.height != h_ || jpeg_.components != cs_.n || jpeg_.precision != 8) {
            return false;
        }
    } else {
        auto buffer = image_.getStreamData(qpdf_dl_specialized);
        size_t need = rowBytes(w_, cs_.n, bpc_) * size_t(h_);
        if (buffer->getSize() < need) return false; // truncated
        samples_.assign(reinterpret_cast<char const*>(buffer->getBuffer()), need);
    }
    return true;
}

void Job::addFlate(Bytes const& samples, int w, int h, int n, int bpc, Candidate base, bool predictor) {
    base.w = w, base.h = h, base.bpc = bpc;
    base.filter = name("/FlateDecode");
    // Predictors pay off on continuous-tone data; on 1-bit and palette data try both when cheap.
    bool try_plain = !predictor || samples.size() <= (4u << 20);
    bool try_predicted = predictor || (bpc < 8 && samples.size() <= (4u << 20));
    auto flate = [&](Candidate& c, Bytes input, char const* label) {
        double t = now();
        c.data = deflate(input.data(), input.size(), estimate_level);
        c.pending = std::move(input);
        c.label = label;
        if (debugging()) c.label += " " + std::to_string(int((now() - t) * 1000)) + "ms";
    };
    if (try_plain) {
        Candidate c = base;
        c.parms = QPDFObjectHandle::newNull();
        flate(c, samples, "flate");
        candidates_.push_back(std::move(c));
    }
    if (try_predicted) {
        size_t row = rowBytes(w, n, bpc);
        size_t bpp = std::max<size_t>(1, size_t(n * bpc) / 8);
        Candidate c = base;
        flate(c, pngPredict(reinterpret_cast<uint8_t const*>(samples.data()), size_t(h), row, bpp), "flate+png");
        c.parms = QPDFObjectHandle::newDictionary({
            {"/Predictor", intObj(15)},
            {"/Colors", intObj(n)},
            {"/BitsPerComponent", intObj(bpc)},
            {"/Columns", intObj(w)},
        });
        candidates_.push_back(std::move(c));
    }
    if (n == 1 && bpc == 1) {
        Candidate c = base;
        c.filter = name("/CCITTFaxDecode");
        c.data = ccittG4(reinterpret_cast<uint8_t const*>(samples.data()), w, h);
        c.label = "g4";
        c.parms = QPDFObjectHandle::newDictionary({
            {"/K", intObj(-1)},
            {"/Columns", intObj(w)},
            {"/Rows", intObj(h)},
        });
        candidates_.push_back(std::move(c));
    }
}

QPDFObjectHandle Job::indexedSpace(QPDFObjectHandle base, int base_n, std::string const& palette) const {
    int entries = int(palette.size()) / base_n;
    return QPDFObjectHandle::newArray({
        name("/Indexed"), base, intObj(entries - 1), QPDFObjectHandle::newString(palette),
    });
}

// Adds lossless encodings of `r` (in colour space `cs`): as is, with fewer bits, or as a palette.
// With `reductions_only`, only the fewer-bits and palette forms (the image itself is a candidate
// already).
void Job::addFromRaster(Raster const& r, ColorSpace const& cs, bool keep_decode, bool lossy, bool resampled,
                        bool reductions_only) {
    Candidate base;
    base.lossy = lossy;
    base.resampled = resampled;
    base.color_space = cs.indexed ? indexedSpace(cs.base, cs.base_n, cs.palette) : cs.object;
    base.drop_decode = !keep_decode;

    if (cs.indexed) {
        int max_index = 0;
        for (uint8_t v : r.px) max_index = std::max<int>(max_index, v);
        int bits = bitsForCount(max_index + 1);
        if (reductions_only && bits >= bpc_) return;
        // A Decode array of an Indexed image depends on the bit depth; it must be the default.
        if (!keep_decode || default_decode_ || bits == bpc_) {
            int out_bits = (keep_decode && !default_decode_) ? bpc_ : bits;
            addFlate(pack(r.px, r.w, r.h, 1, out_bits), r.w, r.h, 1, out_bits, base, false);
        }
        return;
    }

    // Gray with few levels can use fewer bits. Values are scaled 0-255, so this is exact when
    // every value is a multiple of 255 / (2^bits - 1).
    if (r.n == 1) {
        bool b1 = true, b2 = true, b4 = true;
        for (uint8_t v : r.px) {
            b1 = b1 && (v == 0 || v == 255);
            b2 = b2 && v % 85 == 0;
            b4 = b4 && v % 17 == 0;
            if (!b4) break;
        }
        int bits = b1 ? 1 : b2 ? 2 : b4 ? 4 : 8;
        if (bits < 8) {
            std::vector<uint8_t> scaled(r.px.size());
            int div = 255 / ((1 << bits) - 1);
            for (size_t i = 0; i < r.px.size(); ++i) scaled[i] = uint8_t(r.px[i] / div);
            addFlate(pack(scaled, r.w, r.h, 1, bits), r.w, r.h, 1, bits, base, bits >= 4);
            return;
        }
    }

    if (!reductions_only) addFlate(pack(r.px, r.w, r.h, r.n, 8), r.w, r.h, r.n, 8, base, true);

    // A palette, unless a Decode array or colour key refers to the sample values.
    if (!color_key_ && !is_smask_ && (!keep_decode || default_decode_) && r.n <= 4) {
        PaletteResult p = makePalette(r, r.n == 1 ? 16 : 256);
        if (p.fits) {
            Candidate c = base;
            c.color_space = indexedSpace(cs.object, cs.n, p.palette);
            c.drop_decode = true;
            int bits = bitsForCount(p.count);
            addFlate(pack(p.indices, r.w, r.h, 1, bits), r.w, r.h, 1, bits, c, false);
        }
    }
}

void Job::run(double dpi, bool is_smask, bool has_matte, SmolStats& stats) {
    double started = now();
    bool lossy_ok = options_.lossy_images != 0;
    size_t original = raw_.size();

    if (mask_) {
        Candidate base;
        addFlate(samples_, w_, h_, 1, 1, base, false);
    } else {
        // 1. The image as it is, stored better.
        Raster r;
        if (dct_) {
            size_t size = 0;
            auto const* data = reinterpret_cast<unsigned char const*>(raw_.data());
            double t = now();
            if (unsigned char* optimized = smol_jpeg_optimize(data, raw_.size(), &size)) {
                Candidate c;
                c.data.assign(reinterpret_cast<char*>(optimized), size);
                free(optimized);
                c.filter = name("/DCTDecode");
                c.parms = QPDFObjectHandle::newNull();
                c.w = w_, c.h = h_, c.bpc = 8;
                c.label = "jpeg-optimized " + std::to_string(int((now() - t) * 1000)) + "ms";
                candidates_.push_back(std::move(c));
            }
            SmolJPEGInfo info{};
            if (unsigned char* px = smol_jpeg_decode(data, raw_.size(), &info)) {
                r = {w_, h_, cs_.n, std::vector<uint8_t>(px, px + size_t(w_) * h_ * cs_.n)};
                free(px);
            }
        } else {
            Candidate base;
            addFlate(samples_, w_, h_, cs_.n, bpc_, base, !cs_.indexed && bpc_ >= 8);
            if (bpc_ != 16 || lossy_ok) r = unpack(samples_, w_, h_, cs_.n, bpc_, !cs_.indexed);
        }

        if (!r.px.empty()) {
            ColorSpace cs = cs_;
            bool keep_decode = true;
            bool lossy = bpc_ == 16; // 16-bit samples were reduced to 8
            bool recolor_ok = !color_key_ && !has_matte;

            // Fewer bits or a palette may be exact and smaller, whatever else happens below.
            if (!lossy && (bpc_ == 8 || dct_)) addFromRaster(r, cs, true, false, false, true);

            // Colour values in the source's Decode domain are mapped to plain values before
            // changing the colour space (Indexed images map indices, not colours, so skip).
            auto normalize = [&]() {
                if (keep_decode && !default_decode_ && !cs.indexed) {
                    QPDFObjectHandle decode = dict_.getKey("/Decode");
                    for (int c = 0; c < r.n; ++c) {
                        double lo = 0, hi = 1;
                        decode.getArrayItem(2 * c).getValueAsNumber(lo);
                        decode.getArrayItem(2 * c + 1).getValueAsNumber(hi);
                        for (size_t i = size_t(c); i < r.px.size(); i += size_t(r.n)) {
                            double v = lo + r.px[i] / 255.0 * (hi - lo);
                            r.px[i] = uint8_t(std::clamp(std::lround(v * 255), 0L, 255L));
                        }
                    }
                }
                keep_decode = false;
            };
            bool can_recolor = recolor_ok && (default_decode_ || !cs.indexed);

            // 2. Gray, when the image already is (exactly, or within noise for lossy profiles),
            //    or when grayscale was asked for.
            bool changed = false;
            if (can_recolor && (cs.family == Family::RGB || cs.family == Family::CMYK)) {
                uint8_t const* values = cs.indexed ? reinterpret_cast<uint8_t const*>(cs.palette.data()) : r.px.data();
                size_t count = cs.indexed ? cs.palette.size() / size_t(cs.base_n) : r.px.size() / size_t(r.n);
                Grayness g = cs.family == Family::RGB ? grayness(values, count) : Grayness::Color;
                bool to_gray = g == Grayness::Exact || (g == Grayness::Near && lossy_ok) || options_.grayscale_images;
                if (to_gray) {
                    if (!cs.indexed) normalize();
                    values = cs.indexed ? reinterpret_cast<uint8_t const*>(cs.palette.data()) : r.px.data();
                    std::vector<uint8_t> gray = toGray(values, count, cs.family);
                    if (cs.indexed) {
                        cs.palette.assign(gray.begin(), gray.end());
                        cs.base = name("/DeviceGray");
                        cs.base_n = 1;
                    } else {
                        r = {r.w, r.h, 1, std::move(gray)};
                        cs.object = cs.base = name("/DeviceGray");
                        cs.n = cs.base_n = 1;
                    }
                    cs.family = Family::Gray;
                    lossy = lossy || g != Grayness::Exact;
                    changed = true;
                }
            }

            // 3. Black-and-white scans become 1-bit images (at full resolution: sharper and
            //    smaller than a downsampled gray image).
            bool monochrome = false;
            if (lossy_ok && options_.monochrome_scans && !is_smask && can_recolor && !cs.indexed &&
                cs.family == Family::Gray && bpc_ > 1 && dpi >= 150 && (long long)r.w * r.h >= 250000) {
                size_t extreme = 0;
                for (uint8_t v : r.px) extreme += (v <= 48 || v >= 207);
                if (extreme >= r.px.size() * 99 / 100) {
                    normalize();
                    for (auto& v : r.px) v = v >= 128 ? 255 : 0;
                    monochrome = true;
                    lossy = changed = true;
                }
            }

            // 4. Downsampling, except for black-and-white images: as 1-bit images they are
            //    small at full resolution, and downsampling would blur them into gray.
            bool bilevel = monochrome || (bpc_ == 1 && !cs.indexed);
            if (!bilevel && r.n == 1 && !cs.indexed) {
                bilevel = std::all_of(r.px.begin(), r.px.end(), [](uint8_t v) { return v == 0 || v == 255; });
            }
            bool resampled = false;
            if (lossy_ok && !bilevel && options_.max_resolution > 0 && dpi > 0 &&
                dpi > options_.max_resolution * downsample_threshold && !color_key_ &&
                !(cs.indexed && !default_decode_)) {
                double scale = options_.max_resolution / dpi;
                int nw = std::max(1, int(std::lround(r.w * scale)));
                int nh = std::max(1, int(std::lround(r.h * scale)));
                if (nw < r.w && nh < r.h) {
                    if (cs.indexed) {
                        // Resample colours, not indices.
                        Raster expanded{r.w, r.h, cs.base_n, std::vector<uint8_t>(r.px.size() * size_t(cs.base_n))};
                        for (size_t i = 0; i < r.px.size(); ++i) {
                            std::memcpy(&expanded.px[i * size_t(cs.base_n)],
                                        cs.palette.data() + size_t(r.px[i]) * size_t(cs.base_n), size_t(cs.base_n));
                        }
                        r = std::move(expanded);
                        cs.indexed = false;
                        cs.object = cs.base;
                        cs.n = cs.base_n;
                    }
                    r = downscale(r, nw, nh);
                    resampled = lossy = changed = true;
                }
            }

            if (changed) addFromRaster(r, cs, keep_decode, lossy, resampled);

            // 5. JPEG for photographic content.
            bool jpeg_ok = lossy_ok && !is_smask && !bilevel && !color_key_ && !cs.indexed &&
                           (long long)r.w * r.h >= 4096 &&
                           (cs.family == Family::Gray || cs.family == Family::RGB ||
                            (cs.family == Family::CMYK && dct_ && keep_decode));
            if (jpeg_ok && r.n > 1 && makePalette(r).fits) jpeg_ok = false; // few colours: lossless
            if (jpeg_ok && r.n == 1 && !dct_ && !changed && makePalette(r, 16).fits) jpeg_ok = false;
            if (jpeg_ok) {
                int quality = int(std::lround(std::clamp(options_.jpeg_quality, 0.0, 1.0) * 100));
                quality = std::clamp(quality, 1, 100);
                size_t size = 0;
                double t = now();
                unsigned char* jpg = smol_jpeg_encode(r.px.data(), r.w, r.h, r.n, quality, dct_ ? &jpeg_ : nullptr, &size);
                if (jpg) {
                    Candidate c;
                    c.data.assign(reinterpret_cast<char*>(jpg), size);
                    free(jpg);
                    c.filter = name("/DCTDecode");
                    c.parms = QPDFObjectHandle::newNull();
                    c.w = r.w, c.h = r.h, c.bpc = 8;
                    c.color_space = cs.object;
                    c.drop_decode = !keep_decode;
                    c.lossy = true;
                    c.resampled = resampled;
                    c.label = "jpeg q" + std::to_string(quality) + " " + std::to_string(int((now() - t) * 1000)) + "ms";
                    // Re-encoding a JPEG without other changes only adds artefacts; it must pay.
                    if (dct_ && !changed && c.data.size() > original * 9 / 10) c.data.clear();
                    if (!c.data.empty()) candidates_.push_back(std::move(c));
                }
            }
        }
    }

    if (debugging()) {
        std::fprintf(stderr, "image %d %d: %dx%d bpc %d n %d%s%s dpi %.0f, original %zu (%.2fs)\n",
                     image_.getObjGen().getObj(), image_.getObjGen().getGen(), w_, h_, bpc_, cs_.n,
                     dct_ ? " jpeg" : "", cs_.indexed ? " indexed" : "", dpi, original, now() - started);
        for (auto const& c : candidates_) {
            std::fprintf(stderr, "  %-16s %4dx%-4d bpc %d %s%s%s %zu\n", c.label.c_str(), c.w, c.h, c.bpc,
                         c.filter.isName() ? c.filter.getName().c_str() : "-", c.lossy ? " lossy" : "",
                         c.resampled ? " resampled" : "", c.data.size());
        }
    }

    // Pick the smallest, preferring lossless. Flate sizes are estimates until compressed for real,
    // which is done for every candidate close enough to win.
    auto score = [](Candidate const& c) {
        return double(c.data.size()) * (c.lossy ? lossless_preference : 1.0) * (c.pending.empty() ? 1.0 : estimate_gain);
    };
    double lowest = 0;
    for (auto const& c : candidates_) lowest = lowest == 0 ? score(c) : std::min(lowest, score(c));
    for (auto& c : candidates_) {
        if (!c.pending.empty() && score(c) <= lowest * 1.15) {
            c.data = deflate(c.pending.data(), c.pending.size());
            Bytes().swap(c.pending);
        }
    }
    Candidate* best = nullptr;
    for (auto& c : candidates_) {
        if (!best || score(c) < score(*best)) best = &c;
    }
    if (!best) return;
    if (debugging()) std::fprintf(stderr, "  -> %s %zu (%.2fs)\n", best->label.c_str(), best->data.size(), now() - started);
    if (!best->pending.empty()) return; // can't happen: the best is always within reach
    if (best->data.size() + 16 >= original) return;

    image_.replaceStreamData(best->data, best->filter, best->parms);
    dict_.replaceKey("/Width", intObj(best->w));
    dict_.replaceKey("/Height", intObj(best->h));
    if (!mask_) dict_.replaceKey("/BitsPerComponent", intObj(best->bpc));
    if (!best->color_space.isNull()) dict_.replaceKey("/ColorSpace", best->color_space);
    if (best->drop_decode) dict_.removeKey("/Decode");
    dict_.removeKey("/DL");
    image_.setFilterOnWrite(false);

    stats.images_changed++;
    if (best->resampled) stats.images_downsampled++;
    stats.image_bytes_before += (long long)original;
    stats.image_bytes_after += (long long)best->data.size();
}

} // namespace

void optimizeImages(QPDF& pdf, SmolOptions const& options, SmolStats& stats) {
    Resolutions resolutions = findImageResolutions(pdf);

    std::vector<QPDFObjectHandle> images;
    for (auto& obj : reachableObjects(pdf)) {
        if (obj.isStream() && obj.getDict().getKey("/Subtype").isNameAndEquals("/Image")) images.push_back(obj);
    }
    stats.images = long(images.size());

    // Soft masks follow their images: same displayed size, so resolution scales with width.
    std::map<QPDFObjGen, double> smask_dpi;
    std::set<QPDFObjGen> smasks, smask_unknown, matte_parents;
    auto dpiOf = [&](QPDFObjGen og) -> double {
        if (resolutions.unknown.count(og)) return -1;
        auto it = resolutions.dpi.find(og);
        return it == resolutions.dpi.end() ? -1 : it->second;
    };
    for (auto& image : images) {
        QPDFObjectHandle smask = image.getDict().getKey("/SMask");
        if (!smask.isStream()) continue;
        QPDFObjGen og = smask.getObjGen();
        smasks.insert(og);
        if (smask.getDict().hasKey("/Matte")) matte_parents.insert(image.getObjGen());
        int pw = 0, sw = 0;
        double parent = dpiOf(image.getObjGen());
        if (parent <= 0 || !image.getDict().getKey("/Width").getValueAsInt(pw) ||
            !smask.getDict().getKey("/Width").getValueAsInt(sw) || pw <= 0) {
            smask_unknown.insert(og);
            continue;
        }
        double d = parent * sw / pw;
        auto [it, inserted] = smask_dpi.emplace(og, d);
        if (!inserted) it->second = std::min(it->second, d);
    }

    for (auto& image : images) {
        QPDFObjGen og = image.getObjGen();
        bool is_smask = smasks.count(og) > 0;
        double dpi = -1;
        if (is_smask) {
            auto it = smask_dpi.find(og);
            if (!smask_unknown.count(og) && it != smask_dpi.end()) dpi = it->second;
            // Also drawn directly somewhere? Then the larger of both uses decides.
            double direct = dpiOf(og);
            if (resolutions.unknown.count(og)) dpi = -1;
            else if (direct > 0 && dpi > 0) dpi = std::min(dpi, direct);
        } else {
            dpi = dpiOf(og);
        }
        try {
            Job job(image, options, is_smask);
            if (job.prepare()) job.run(dpi, is_smask, matte_parents.count(og) > 0, stats);
        } catch (std::exception&) {
            // Leave this image as it is.
        }
        image.setFilterOnWrite(false);
    }
}

} // namespace smol
