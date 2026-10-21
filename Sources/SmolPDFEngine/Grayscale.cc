// Converts the colours of text and vector graphics to gray (images are handled in Images.cc).
//
// Three kinds of places hold colours:
//   - content-stream operators: rg/RG and k/K become g/G; sc/scn/SC/SCN values in an RGB or CMYK
//     colour space are reduced to one gray value;
//   - colour space resources used by those operators: RGB and CMYK spaces become DeviceGray,
//     palettes (Indexed) are converted entry by entry;
//   - shadings, whose colour functions can't be rewritten: their RGB or CMYK space is replaced by a
//     DeviceN space that takes the same components and maps them to gray.
// Spot colours (Separation, DeviceN) and Lab are left as they are.

#include "Engine.hh"

#include <qpdf/Pl_String.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFTokenizer.hh>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <vector>

namespace smol {
namespace {

// What colour values in a colour space look like, for those that need converting.
enum class Kind { None, RGB, CMYK, PatternRGB, PatternCMYK };

int components(Kind k) {
    return k == Kind::RGB || k == Kind::PatternRGB ? 3 : k == Kind::CMYK || k == Kind::PatternCMYK ? 4 : 0;
}

Kind deviceKind(QPDFObjectHandle cs) {
    if (cs.isName()) {
        std::string n = cs.getName();
        if (n == "/DeviceRGB" || n == "/RGB") return Kind::RGB;
        if (n == "/DeviceCMYK" || n == "/CMYK") return Kind::CMYK;
    } else if (cs.isArray() && cs.getArrayNItems() >= 1 && cs.getArrayItem(0).isName()) {
        std::string n = cs.getArrayItem(0).getName();
        if (n == "/CalRGB") return Kind::RGB;
        if (n == "/ICCBased" && cs.getArrayNItems() >= 2 && cs.getArrayItem(1).isStream()) {
            int count = 0;
            cs.getArrayItem(1).getDict().getKey("/N").getValueAsInt(count);
            return count == 3 ? Kind::RGB : count == 4 ? Kind::CMYK : Kind::None;
        }
    }
    return Kind::None;
}

// How colour values set in this colour space must be rewritten.
Kind operandKind(QPDFObjectHandle cs) {
    if (cs.isArray() && cs.getArrayNItems() == 2 && cs.getArrayItem(0).isNameAndEquals("/Pattern")) {
        Kind base = deviceKind(cs.getArrayItem(1));
        return base == Kind::RGB ? Kind::PatternRGB : base == Kind::CMYK ? Kind::PatternCMYK : Kind::None;
    }
    return deviceKind(cs);
}

double gray(Kind kind, double const* v) {
    if (components(kind) == 3) return 0.299 * v[0] + 0.587 * v[1] + 0.114 * v[2];
    return 1 - std::min(1.0, 0.3 * v[0] + 0.59 * v[1] + 0.11 * v[2] + v[3]);
}

std::string number(double v) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.4f", std::clamp(v, 0.0, 1.0));
    std::string s = buf;
    s.erase(s.find_last_not_of('0') + 1);
    if (s.back() == '.') s.pop_back();
    return s;
}

// A palette with gray entries, or null when the space isn't an RGB or CMYK palette.
QPDFObjectHandle grayPalette(QPDFObjectHandle cs) {
    if (!cs.isArray() || cs.getArrayNItems() != 4 || !cs.getArrayItem(0).isNameAndEquals("/Indexed")) {
        return QPDFObjectHandle::newNull();
    }
    Kind base = deviceKind(cs.getArrayItem(1));
    int n = components(base), hival = 0;
    if (!n || !cs.getArrayItem(2).getValueAsInt(hival) || hival < 0 || hival > 255) return QPDFObjectHandle::newNull();
    QPDFObjectHandle lookup = cs.getArrayItem(3);
    std::string table;
    if (lookup.isString()) {
        table = lookup.getStringValue();
    } else if (lookup.isStream()) {
        auto buffer = lookup.getStreamData(qpdf_dl_specialized);
        table.assign(reinterpret_cast<char const*>(buffer->getBuffer()), buffer->getSize());
    }
    if (table.size() < size_t(hival + 1) * size_t(n)) return QPDFObjectHandle::newNull();
    std::string grays;
    for (int i = 0; i <= hival; ++i) {
        double v[4];
        for (int c = 0; c < n; ++c) v[c] = uint8_t(table[size_t(i * n + c)]) / 255.0;
        grays.push_back(char(std::lround(gray(base, v) * 255)));
    }
    return QPDFObjectHandle::newArray({
        QPDFObjectHandle::newName("/Indexed"), QPDFObjectHandle::newName("/DeviceGray"),
        QPDFObjectHandle::newInteger(hival), QPDFObjectHandle::newString(grays),
    });
}

// The gray replacement for a colour space resource used by content operators, or null.
QPDFObjectHandle grayResource(QPDFObjectHandle cs) {
    switch (operandKind(cs)) {
    case Kind::RGB:
    case Kind::CMYK: return QPDFObjectHandle::newName("/DeviceGray");
    case Kind::PatternRGB:
    case Kind::PatternCMYK:
        return QPDFObjectHandle::newArray({QPDFObjectHandle::newName("/Pattern"), QPDFObjectHandle::newName("/DeviceGray")});
    case Kind::None: return grayPalette(cs);
    }
    return QPDFObjectHandle::newNull();
}

// A colour space taking the same RGB or CMYK components but showing gray, for shadings.
QPDFObjectHandle grayDeviceN(QPDF& pdf, Kind kind) {
    bool rgb = kind == Kind::RGB;
    // PostScript calculator functions; the Range clips the result to 0-1.
    std::string code = rgb ? "{0.114 mul exch 0.587 mul add exch 0.299 mul add}"
                           : "{exch 0.11 mul add exch 0.59 mul add exch 0.3 mul add 1 exch sub}";
    QPDFObjectHandle function = pdf.newStream(code);
    QPDFObjectHandle domain = QPDFObjectHandle::newArray();
    QPDFObjectHandle names = QPDFObjectHandle::newArray();
    for (int i = 0; i < (rgb ? 3 : 4); ++i) {
        domain.appendItem(QPDFObjectHandle::newInteger(0));
        domain.appendItem(QPDFObjectHandle::newInteger(1));
        names.appendItem(QPDFObjectHandle::newName((rgb ? "/smol-rgb-" : "/smol-cmyk-") + std::to_string(i)));
    }
    QPDFObjectHandle dict = function.getDict();
    dict.replaceKey("/FunctionType", QPDFObjectHandle::newInteger(4));
    dict.replaceKey("/Domain", domain);
    dict.replaceKey("/Range", QPDFObjectHandle::newArray({QPDFObjectHandle::newInteger(0), QPDFObjectHandle::newInteger(1)}));
    return QPDFObjectHandle::newArray({
        QPDFObjectHandle::newName("/DeviceN"), names, QPDFObjectHandle::newName("/DeviceGray"), function,
    });
}

// Rewrites colour operators, given what the named colour spaces of the content's resources hold.
class GrayFilter: public QPDFObjectHandle::TokenFilter {
  public:
    explicit GrayFilter(std::map<std::string, Kind> spaces) :
        spaces_(std::move(spaces)) {}

    void handleToken(QPDFTokenizer::Token const& token) override {
        if (token.getType() != QPDFTokenizer::tt_word) {
            pending_.push_back(token);
            return;
        }
        std::string replacement;
        if (rewrite(token.getValue(), replacement)) {
            write(replacement);
        } else {
            flush();
            writeToken(token);
        }
        pending_.clear();
    }

    void handleEOF() override { flush(); }

  private:
    struct State {
        Kind fill = Kind::None, stroke = Kind::None;
    };

    void flush() {
        for (auto const& t : pending_) writeToken(t);
        pending_.clear();
    }

    // Operands since the last operator, without whitespace and comments.
    std::vector<QPDFTokenizer::Token> operands() const {
        std::vector<QPDFTokenizer::Token> out;
        for (auto const& t : pending_) {
            if (t.getType() != QPDFTokenizer::tt_space && t.getType() != QPDFTokenizer::tt_comment) out.push_back(t);
        }
        return out;
    }

    static bool numbers(std::vector<QPDFTokenizer::Token> const& ops, size_t count, double* v) {
        if (count > ops.size()) return false;
        for (size_t i = 0; i < count; ++i) {
            auto type = ops[i].getType();
            if (type != QPDFTokenizer::tt_integer && type != QPDFTokenizer::tt_real) return false;
            v[i] = std::atof(ops[i].getValue().c_str());
        }
        return true;
    }

    // Tracks the colour state; returns true with the text to write when the operator changes.
    bool rewrite(std::string const& op, std::string& out) {
        bool stroke = op == "G" || op == "RG" || op == "K" || op == "CS" || op == "SC" || op == "SCN";
        Kind& current = stroke ? state_.stroke : state_.fill;
        auto ops = operands();
        double v[4];

        if (op == "q") {
            stack_.push_back(state_);
        } else if (op == "Q") {
            if (!stack_.empty()) {
                state_ = stack_.back();
                stack_.pop_back();
            }
        } else if (op == "g" || op == "G") {
            current = Kind::None;
        } else if (op == "rg" || op == "RG" || op == "k" || op == "K") {
            Kind kind = op.size() == 2 ? Kind::RGB : Kind::CMYK;
            current = kind; // a later sc in this implicit device space needs converting too
            if (ops.size() != size_t(components(kind)) || !numbers(ops, ops.size(), v)) return false;
            out = " " + number(gray(kind, v)) + (stroke ? " G" : " g");
            return true;
        } else if ((op == "cs" || op == "CS") && ops.size() == 1 && ops[0].getType() == QPDFTokenizer::tt_name) {
            std::string name = ops[0].getValue();
            if (name == "/DeviceRGB" || name == "/DeviceCMYK") {
                current = name == "/DeviceRGB" ? Kind::RGB : Kind::CMYK;
                out = " /DeviceGray " + op;
                return true;
            }
            auto found = spaces_.find(name);
            current = found == spaces_.end() ? Kind::None : found->second;
        } else if (op == "sc" || op == "scn" || op == "SC" || op == "SCN") {
            size_t n = size_t(components(current));
            bool pattern = current == Kind::PatternRGB || current == Kind::PatternCMYK;
            if (n && ops.size() == n + (pattern ? 1 : 0) && numbers(ops, n, v)) {
                out = " " + number(gray(current, v));
                if (pattern) out += " " + ops.back().getRawValue();
                out += " " + op;
                return true;
            }
        }
        return false;
    }

    std::map<std::string, Kind> spaces_;
    std::vector<QPDFTokenizer::Token> pending_;
    State state_;
    std::vector<State> stack_;
};

// A content stream with the resources its names refer to.
struct Content {
    QPDFObjectHandle owner; // page, form XObject, tiling pattern or Type 3 glyph
    bool is_page = false;
    QPDFObjectHandle color_spaces; // the resources' /ColorSpace dictionary (or null)
};

std::map<std::string, Kind> kindsOf(QPDFObjectHandle color_spaces) {
    std::map<std::string, Kind> kinds;
    if (!color_spaces.isDictionary()) return kinds;
    for (auto const& [name, cs] : color_spaces.getDictAsMap()) {
        Kind k = operandKind(cs);
        if (k != Kind::None) kinds[name] = k;
    }
    return kinds;
}

QPDFObjectHandle colorSpacesOf(QPDFObjectHandle resources) {
    return resources.isDictionary() ? resources.getKey("/ColorSpace") : QPDFObjectHandle::newNull();
}

} // namespace

void convertToGray(QPDF& pdf) {
    // 1. Every content stream, with its colour spaces as they are now.
    std::vector<Content> contents;
    for (auto& page : QPDFPageDocumentHelper(pdf).getAllPages()) {
        contents.push_back({page.getObjectHandle(), true, colorSpacesOf(page.getAttribute("/Resources", false))});
    }
    auto objects = reachableObjects(pdf);
    for (auto& obj : objects) {
        QPDFObjectHandle dict = obj.isStream() ? obj.getDict() : obj;
        if (!dict.isDictionary()) continue;
        int pattern_type = 0;
        dict.getKey("/PatternType").getValueAsInt(pattern_type);
        if (obj.isStream() && (dict.getKey("/Subtype").isNameAndEquals("/Form") || pattern_type == 1)) {
            contents.push_back({obj, false, colorSpacesOf(dict.getKey("/Resources"))});
        } else if (dict.getKey("/Subtype").isNameAndEquals("/Type3") && dict.getKey("/CharProcs").isDictionary()) {
            QPDFObjectHandle spaces = colorSpacesOf(dict.getKey("/Resources"));
            for (auto const& [name, glyph] : dict.getKey("/CharProcs").getDictAsMap()) {
                if (glyph.isStream()) contents.push_back({glyph, false, spaces});
            }
        }
    }

    // 2. Rewrite their colour operators. Colour spaces whose users can't all be rewritten stay.
    std::vector<QPDFObjectHandle> keep;
    for (auto& c : contents) {
        try {
            GrayFilter filter(kindsOf(c.color_spaces));
            std::string out;
            Pl_String pipeline("gray", nullptr, out);
            if (c.is_page) {
                QPDFPageObjectHelper(c.owner).filterContents(&filter, &pipeline);
                c.owner.replaceKey("/Contents", pdf.newStream(out));
            } else {
                c.owner.filterAsContents(&filter, &pipeline);
                c.owner.replaceStreamData(out, QPDFObjectHandle::newNull(), QPDFObjectHandle::newNull());
            }
        } catch (std::exception&) {
            if (c.color_spaces.isDictionary()) keep.push_back(c.color_spaces);
        }
    }

    // 3. The colour space resources those operators use.
    std::vector<QPDFObjectHandle> done;
    auto among = [](std::vector<QPDFObjectHandle> const& list, QPDFObjectHandle const& h) {
        return std::any_of(list.begin(), list.end(), [&](QPDFObjectHandle const& x) { return x.isSameObjectAs(h); });
    };
    for (auto& c : contents) {
        QPDFObjectHandle spaces = c.color_spaces;
        if (!spaces.isDictionary() || among(keep, spaces) || among(done, spaces)) continue;
        done.push_back(spaces);
        for (auto const& [name, cs] : spaces.getDictAsMap()) {
            QPDFObjectHandle replacement = grayResource(cs);
            if (!replacement.isNull()) spaces.replaceKey(name, replacement);
        }
    }

    // 4. Shadings and transparency groups, which are often direct objects inside others.
    QPDFObjectHandle rgb, cmyk; // shared DeviceN spaces, made on first use
    auto convert = [&](QPDFObjectHandle dict) {
        if (dict.hasKey("/ShadingType")) {
            QPDFObjectHandle cs = dict.getKey("/ColorSpace");
            Kind k = deviceKind(cs);
            if (k == Kind::RGB) {
                if (!rgb.isInitialized()) rgb = pdf.makeIndirectObject(grayDeviceN(pdf, Kind::RGB));
                dict.replaceKey("/ColorSpace", rgb);
            } else if (k == Kind::CMYK) {
                if (!cmyk.isInitialized()) cmyk = pdf.makeIndirectObject(grayDeviceN(pdf, Kind::CMYK));
                dict.replaceKey("/ColorSpace", cmyk);
            } else {
                QPDFObjectHandle palette = grayPalette(cs);
                if (!palette.isNull()) dict.replaceKey("/ColorSpace", palette);
            }
        } else if (dict.getKey("/S").isNameAndEquals("/Transparency") && deviceKind(dict.getKey("/CS")) != Kind::None) {
            dict.replaceKey("/CS", QPDFObjectHandle::newName("/DeviceGray"));
        }
    };
    std::function<void(QPDFObjectHandle, int)> visit = [&](QPDFObjectHandle obj, int depth) {
        if (depth > 32) return;
        QPDFObjectHandle dict = obj.isStream() ? obj.getDict() : obj;
        if (dict.isDictionary()) {
            convert(dict);
            for (auto const& [key, item] : dict.getDictAsMap()) {
                if (!item.isIndirect()) visit(item, depth + 1);
            }
        } else if (obj.isArray()) {
            for (auto const& item : obj.getArrayAsVector()) {
                if (!item.isIndirect()) visit(item, depth + 1);
            }
        }
    };
    for (auto& obj : objects) visit(obj, 0);
}

} // namespace smol
