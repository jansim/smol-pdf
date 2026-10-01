// Lossless encoders: Flate (libdeflate), PNG predictors and CCITT Group 4.

#include "Engine.hh"

#include <libdeflate.h>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <vector>

namespace smol {

// Flate -------------------------------------------------------------------------------------------

namespace {
struct CompressorDeleter {
    void operator()(libdeflate_compressor* c) const { libdeflate_free_compressor(c); }
};
} // namespace

Bytes deflate(void const* data, size_t size, int level) {
    // Level 12 is libdeflate's best; drop a little for very large streams.
    if (level <= 0 || level > 12) level = size <= (16u << 20) ? 12 : size <= (64u << 20) ? 9 : 6;
    thread_local std::unique_ptr<libdeflate_compressor, CompressorDeleter> compressors[13];
    auto& compressor = compressors[level];
    if (!compressor) {
        compressor.reset(libdeflate_alloc_compressor(level));
        if (!compressor) throw std::bad_alloc();
    }
    Bytes out(libdeflate_zlib_compress_bound(compressor.get(), size), '\0');
    size_t written = libdeflate_zlib_compress(compressor.get(), data, size, out.data(), out.size());
    if (written == 0) throw std::runtime_error("deflate failed");
    out.resize(written);
    return out;
}

// PNG predictors ----------------------------------------------------------------------------------

Bytes pngPredict(uint8_t const* data, size_t rows, size_t row_bytes, size_t bpp) {
    Bytes out;
    out.resize(rows * (row_bytes + 1));
    std::vector<uint8_t> zero(row_bytes, 0);
    std::vector<uint8_t> candidate[5];
    for (auto& c : candidate) c.resize(row_bytes);

    for (size_t y = 0; y < rows; ++y) {
        uint8_t const* cur = data + y * row_bytes;
        uint8_t const* up = y ? data + (y - 1) * row_bytes : zero.data();
        for (size_t x = 0; x < row_bytes; ++x) {
            int a = x >= bpp ? cur[x - bpp] : 0;
            int b = up[x];
            int c = x >= bpp ? up[x - bpp] : 0;
            int p = a + b - c;
            int pa = std::abs(p - a), pb = std::abs(p - b), pc = std::abs(p - c);
            int paeth = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
            candidate[0][x] = cur[x];
            candidate[1][x] = uint8_t(cur[x] - a);
            candidate[2][x] = uint8_t(cur[x] - b);
            candidate[3][x] = uint8_t(cur[x] - ((a + b) >> 1));
            candidate[4][x] = uint8_t(cur[x] - paeth);
        }
        // The usual heuristic: the filter whose output has the smallest sum of signed magnitudes.
        int best = 0;
        unsigned long long best_cost = ~0ULL;
        for (int f = 0; f < 5; ++f) {
            unsigned long long cost = 0;
            for (uint8_t v : candidate[f]) cost += unsigned(std::abs(int(int8_t(v))));
            if (cost < best_cost) {
                best_cost = cost;
                best = f;
            }
        }
        char* row = out.data() + y * (row_bytes + 1);
        row[0] = char(best);
        std::memcpy(row + 1, candidate[best].data(), row_bytes);
    }
    return out;
}

// CCITT Group 4 -----------------------------------------------------------------------------------
//
// Follows ITU-T T.6 (and libtiff's Fax3Encode2DRow). Code tables are from ITU-T T.4.

namespace {

struct Code {
    uint16_t bits;
    uint8_t length;
};

Code parseCode(char const* s) {
    Code c{0, 0};
    for (; *s; ++s) {
        c.bits = uint16_t((c.bits << 1) | (*s == '1'));
        ++c.length;
    }
    return c;
}

// Terminating codes for runs 0-63.
char const* const white_terminating[64] = {
    "00110101", "000111", "0111", "1000", "1011", "1100", "1110", "1111", "10011", "10100",
    "00111", "01000", "001000", "000011", "110100", "110101", "101010", "101011", "0100111",
    "0001100", "0001000", "0010111", "0000011", "0000100", "0101000", "0101011", "0010011",
    "0100100", "0011000", "00000010", "00000011", "00011010", "00011011", "00010010", "00010011",
    "00010100", "00010101", "00010110", "00010111", "00101000", "00101001", "00101010",
    "00101011", "00101100", "00101101", "00000100", "00000101", "00001010", "00001011",
    "01010010", "01010011", "01010100", "01010101", "00100100", "00100101", "01011000",
    "01011001", "01011010", "01011011", "01001010", "01001011", "00110010", "00110011",
    "00110100",
};
char const* const black_terminating[64] = {
    "0000110111", "010", "11", "10", "011", "0011", "0010", "00011", "000101", "000100",
    "0000100", "0000101", "0000111", "00000100", "00000111", "000011000", "0000010111",
    "0000011000", "0000001000", "00001100111", "00001101000", "00001101100", "00000110111",
    "00000101000", "00000010111", "00000011000", "000011001010", "000011001011", "000011001100",
    "000011001101", "000001101000", "000001101001", "000001101010", "000001101011",
    "000011010010", "000011010011", "000011010100", "000011010101", "000011010110",
    "000011010111", "000001101100", "000001101101", "000011011010", "000011011011",
    "000001010100", "000001010101", "000001010110", "000001010111", "000001100100",
    "000001100101", "000001010010", "000001010011", "000000100100", "000000110111",
    "000000111000", "000000100111", "000000101000", "000001011000", "000001011001",
    "000000101011", "000000101100", "000001011010", "000001100110", "000001100111",
};
// Make-up codes for runs 64, 128, ..., 1728.
char const* const white_makeup[27] = {
    "11011", "10010", "010111", "0110111", "00110110", "00110111", "01100100", "01100101",
    "01101000", "01100111", "011001100", "011001101", "011010010", "011010011", "011010100",
    "011010101", "011010110", "011010111", "011011000", "011011001", "011011010", "011011011",
    "010011000", "010011001", "010011010", "011000", "010011011",
};
char const* const black_makeup[27] = {
    "0000001111", "000011001000", "000011001001", "000001011011", "000000110011",
    "000000110100", "000000110101", "0000001101100", "0000001101101", "0000001001010",
    "0000001001011", "0000001001100", "0000001001101", "0000001110010", "0000001110011",
    "0000001110100", "0000001110101", "0000001110110", "0000001110111", "0000001010010",
    "0000001010011", "0000001010100", "0000001010101", "0000001011010", "0000001011011",
    "0000001100100", "0000001100101",
};
// Make-up codes for runs 1792, 1856, ..., 2560, shared by both colours.
char const* const extended_makeup[13] = {
    "00000001000", "00000001100", "00000001101", "000000010010", "000000010011", "000000010100",
    "000000010101", "000000010110", "000000010111", "000000011100", "000000011101",
    "000000011110", "000000011111",
};

struct RunTable {
    Code terminating[64];
    Code makeup[40]; // index n is the code for a run of (n + 1) * 64
};

struct Tables {
    RunTable white, black;
    Code pass = parseCode("0001");
    Code horizontal = parseCode("001");
    // Vertical modes by b1 - a1 + 3: VR3, VR2, VR1, V0, VL1, VL2, VL3.
    Code vertical[7] = {
        parseCode("0000011"), parseCode("000011"), parseCode("011"), parseCode("1"),
        parseCode("010"), parseCode("000010"), parseCode("0000010"),
    };
    Code eol = parseCode("000000000001");

    Tables() {
        for (int i = 0; i < 64; ++i) {
            white.terminating[i] = parseCode(white_terminating[i]);
            black.terminating[i] = parseCode(black_terminating[i]);
        }
        for (int i = 0; i < 27; ++i) {
            white.makeup[i] = parseCode(white_makeup[i]);
            black.makeup[i] = parseCode(black_makeup[i]);
        }
        for (int i = 0; i < 13; ++i) {
            white.makeup[27 + i] = black.makeup[27 + i] = parseCode(extended_makeup[i]);
        }
    }
};

Tables const& tables() {
    static Tables const t;
    return t;
}

class BitWriter {
  public:
    void put(Code c) {
        for (int i = c.length - 1; i >= 0; --i) {
            acc_ = uint8_t((acc_ << 1) | ((c.bits >> i) & 1));
            if (++count_ == 8) {
                out_.push_back(char(acc_));
                acc_ = 0;
                count_ = 0;
            }
        }
    }
    void putRun(int run, RunTable const& table) {
        while (run >= 2624) {
            put(table.makeup[2560 / 64 - 1]);
            run -= 2560;
        }
        if (run >= 64) {
            put(table.makeup[run / 64 - 1]);
            run %= 64;
        }
        put(table.terminating[run]);
    }
    Bytes finish() {
        if (count_) out_.push_back(char(acc_ << (8 - count_)));
        return std::move(out_);
    }

  private:
    Bytes out_;
    uint8_t acc_ = 0;
    int count_ = 0;
};

// Colours as in the coding: 1 is black (sample value 0), 0 is white.
inline int colorAt(uint8_t const* row, int x, int width) {
    if (x >= width) return 0;
    return ((row[x >> 3] >> (7 - (x & 7))) & 1) ? 0 : 1;
}

// First position >= start whose colour differs from `color`, or `width`.
int findDiff(uint8_t const* row, int start, int width, int color) {
    uint8_t const skip = color ? 0x00 : 0xFF; // a byte entirely of `color`
    int x = start;
    while (x < width) {
        if ((x & 7) == 0 && x + 8 <= width && row[x >> 3] == skip) {
            x += 8;
            continue;
        }
        if (colorAt(row, x, width) != color) return x;
        ++x;
    }
    return width;
}

inline int findDiff2(uint8_t const* row, int start, int width, int color) {
    return start < width ? findDiff(row, start, width, color) : width;
}

} // namespace

Bytes ccittG4(uint8_t const* bits, int width, int height) {
    Tables const& t = tables();
    BitWriter w;
    size_t stride = (size_t(width) + 7) / 8;
    std::vector<uint8_t> white_line(stride, 0xFF);
    uint8_t const* ref = white_line.data();

    for (int y = 0; y < height; ++y) {
        uint8_t const* cur = bits + stride * size_t(y);
        int a0 = 0;
        int a1 = colorAt(cur, 0, width) ? 0 : findDiff(cur, 0, width, 0);
        int b1 = colorAt(ref, 0, width) ? 0 : findDiff(ref, 0, width, 0);
        for (;;) {
            int b2 = findDiff2(ref, b1, width, colorAt(ref, b1, width));
            if (b2 >= a1) {
                int d = b1 - a1;
                if (d < -3 || d > 3) {
                    int a2 = findDiff2(cur, a1, width, colorAt(cur, a1, width));
                    w.put(t.horizontal);
                    if (a0 + a1 == 0 || colorAt(cur, a0, width) == 0) {
                        w.putRun(a1 - a0, t.white);
                        w.putRun(a2 - a1, t.black);
                    } else {
                        w.putRun(a1 - a0, t.black);
                        w.putRun(a2 - a1, t.white);
                    }
                    a0 = a2;
                } else {
                    w.put(t.vertical[d + 3]);
                    a0 = a1;
                }
            } else {
                w.put(t.pass);
                a0 = b2;
            }
            if (a0 >= width) break;
            int color = colorAt(cur, a0, width);
            a1 = findDiff(cur, a0, width, color);
            b1 = findDiff(ref, a0, width, !color);
            b1 = findDiff(ref, b1, width, color);
        }
        ref = cur;
    }
    w.put(t.eol);
    w.put(t.eol);
    return w.finish();
}

// JBIG2 ------------------------------------------------------------------------------------------
//
// A lossless generic region (ITU-T T.88 6.2) coded with the MQ arithmetic coder (Annex E), as an
// embedded stream for PDF's JBIG2Decode: a page information segment and an immediate generic
// region segment, without file header or end-of-page segment.

namespace {

struct MQState {
    uint16_t qe;
    uint8_t nmps, nlps, swtch;
};

MQState const mq_table[47] = {
    {0x5601, 1, 1, 1},   {0x3401, 2, 6, 0},   {0x1801, 3, 9, 0},   {0x0AC1, 4, 12, 0},
    {0x0521, 5, 29, 0},  {0x0221, 38, 33, 0}, {0x5601, 7, 6, 1},   {0x5401, 8, 14, 0},
    {0x4801, 9, 14, 0},  {0x3801, 10, 14, 0}, {0x3001, 11, 17, 0}, {0x2401, 12, 18, 0},
    {0x1C01, 13, 20, 0}, {0x1601, 29, 21, 0}, {0x5601, 15, 14, 1}, {0x5401, 16, 14, 0},
    {0x5101, 17, 15, 0}, {0x4801, 18, 16, 0}, {0x3801, 19, 17, 0}, {0x3401, 20, 18, 0},
    {0x3001, 21, 19, 0}, {0x2801, 22, 19, 0}, {0x2401, 23, 20, 0}, {0x2201, 24, 21, 0},
    {0x1C01, 25, 22, 0}, {0x1801, 26, 23, 0}, {0x1601, 27, 24, 0}, {0x1401, 28, 25, 0},
    {0x1201, 29, 26, 0}, {0x1101, 30, 27, 0}, {0x0AC1, 31, 28, 0}, {0x09C1, 32, 29, 0},
    {0x08A1, 33, 30, 0}, {0x0521, 34, 31, 0}, {0x0441, 35, 32, 0}, {0x02A1, 36, 33, 0},
    {0x0221, 37, 34, 0}, {0x0141, 38, 35, 0}, {0x0111, 39, 36, 0}, {0x0085, 40, 37, 0},
    {0x0049, 41, 38, 0}, {0x0025, 42, 39, 0}, {0x0015, 43, 40, 0}, {0x0009, 44, 41, 0},
    {0x0005, 45, 42, 0}, {0x0001, 45, 43, 0}, {0x5601, 46, 46, 0},
};

class MQEncoder {
  public:
    explicit MQEncoder(size_t contexts) :
        index_(contexts, 0),
        mps_(contexts, 0) {}

    void encode(int bit, uint32_t cx) {
        uint8_t& i = index_[cx];
        uint8_t& mps = mps_[cx];
        uint32_t qe = mq_table[i].qe;
        a_ -= qe;
        if (bit == mps) {
            if ((a_ & 0x8000) == 0) {
                if (a_ < qe) a_ = qe;
                else c_ += qe;
                i = mq_table[i].nmps;
                renormalize();
            } else {
                c_ += qe;
            }
        } else {
            if (a_ < qe) c_ += qe;
            else a_ = qe;
            if (mq_table[i].swtch) mps = uint8_t(1 - mps);
            i = mq_table[i].nlps;
            renormalize();
        }
    }

    Bytes finish() {
        uint32_t temp = c_ + a_;
        c_ |= 0xFFFF;
        if (c_ >= temp) c_ -= 0x8000;
        c_ <<= ct_;
        byteOut();
        c_ <<= ct_;
        byteOut();
        if (b_ != 0xFF) put(0xFF);
        put(0xAC);
        out_.erase(out_.begin()); // the placeholder before the first byte
        return std::move(out_);
    }

  private:
    void put(uint8_t byte) {
        out_.push_back(char(byte));
        b_ = byte;
    }

    void renormalize() {
        do {
            a_ <<= 1;
            c_ <<= 1;
            if (--ct_ == 0) byteOut();
        } while ((a_ & 0x8000) == 0);
    }

    void byteOut() {
        if (b_ == 0xFF) {
            put(uint8_t(c_ >> 20));
            c_ &= 0xFFFFF;
            ct_ = 7;
        } else if (c_ < 0x8000000) {
            put(uint8_t(c_ >> 19));
            c_ &= 0x7FFFF;
            ct_ = 8;
        } else {
            // Carry into the byte already written.
            b_ = uint8_t(b_ + 1);
            out_.back() = char(b_);
            if (b_ == 0xFF) {
                c_ &= 0x7FFFFFF;
                put(uint8_t(c_ >> 20));
                c_ &= 0xFFFFF;
                ct_ = 7;
            } else {
                put(uint8_t(c_ >> 19));
                c_ &= 0x7FFFF;
                ct_ = 8;
            }
        }
    }

    std::vector<uint8_t> index_, mps_;
    uint32_t a_ = 0x8000, c_ = 0;
    int ct_ = 12;
    uint8_t b_ = 0;
    Bytes out_ = Bytes(1, '\0');
};

void put32(Bytes& out, uint32_t v) {
    out.push_back(char(v >> 24));
    out.push_back(char(v >> 16));
    out.push_back(char(v >> 8));
    out.push_back(char(v));
}

void segment(Bytes& out, uint32_t number, uint8_t type, Bytes const& data) {
    put32(out, number);
    out.push_back(char(type)); // flags: 1-byte page association
    out.push_back(0);          // no referred-to segments
    out.push_back(1);          // page 1
    put32(out, uint32_t(data.size()));
    out += data;
}

} // namespace

Bytes jbig2Generic(uint8_t const* bits, int width, int height) {
    size_t stride = (size_t(width) + 7) / 8;
    // JBIG2 codes black as 1; PDF's JBIG2Decode inverts, so black is sample value 0 as in G4.
    std::vector<uint8_t> image(stride * size_t(height));
    for (size_t i = 0; i < image.size(); ++i) image[i] = uint8_t(~bits[i]);
    if (width % 8) {
        uint8_t keep = uint8_t(0xFF << (8 - width % 8));
        for (int y = 0; y < height; ++y) image[stride * size_t(y) + stride - 1] &= keep;
    }
    auto pixel = [&](int x, int y) -> uint32_t {
        if (x < 0 || x >= width || y < 0) return 0;
        return (image[stride * size_t(y) + size_t(x >> 3)] >> (7 - (x & 7))) & 1;
    };

    // Generic template 0 with the nominal adaptive pixels, and typical prediction (TPGDON):
    // rows equal to the one above cost a single decision.
    MQEncoder mq(1 << 16);
    int ltp = 0;
    std::vector<uint8_t> zero(stride, 0);
    for (int y = 0; y < height; ++y) {
        uint8_t const* row = image.data() + stride * size_t(y);
        uint8_t const* above = y ? row - stride : zero.data();
        int same = std::memcmp(row, above, stride) == 0;
        mq.encode(same ^ ltp, 0x9B25);
        ltp = same;
        if (ltp) continue;
        for (int x = 0; x < width; ++x) {
            uint32_t cx = pixel(x - 1, y) | pixel(x - 2, y) << 1 | pixel(x - 3, y) << 2 | pixel(x - 4, y) << 3 |
                          pixel(x + 3, y - 1) << 4 | pixel(x + 2, y - 1) << 5 | pixel(x + 1, y - 1) << 6 |
                          pixel(x, y - 1) << 7 | pixel(x - 1, y - 1) << 8 | pixel(x - 2, y - 1) << 9 |
                          pixel(x - 3, y - 1) << 10 | pixel(x + 2, y - 2) << 11 | pixel(x + 1, y - 2) << 12 |
                          pixel(x, y - 2) << 13 | pixel(x - 1, y - 2) << 14 | pixel(x - 2, y - 2) << 15;
            mq.encode(int(pixel(x, y)), cx);
        }
    }

    Bytes page;
    put32(page, uint32_t(width));
    put32(page, uint32_t(height));
    put32(page, 0); // resolution unknown
    put32(page, 0);
    page.push_back(1); // eventually lossless, default pixel white, OR
    page.push_back(0); // not striped
    page.push_back(0);

    Bytes region;
    put32(region, uint32_t(width));
    put32(region, uint32_t(height));
    put32(region, 0); // at 0, 0
    put32(region, 0);
    region.push_back(0);        // combination operator OR
    region.push_back(0x08);     // arithmetic coding, template 0, TPGDON
    for (int8_t at : {3, -1, -3, -1, 2, -2, -2, -2}) region.push_back(char(at));
    region += mq.finish();

    Bytes out;
    segment(out, 0, 48, page);   // page information
    segment(out, 1, 38, region); // immediate generic region
    return out;
}

} // namespace smol
