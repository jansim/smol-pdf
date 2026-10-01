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

} // namespace smol
