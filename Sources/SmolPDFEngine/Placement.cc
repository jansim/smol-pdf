// Finds the resolution at which each image is drawn, by following the graphics state through page
// and form XObject content streams.

#include "Engine.hh"

#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>

#include <cmath>
#include <deque>
#include <utility>
#include <vector>

namespace smol {

namespace {

// A PDF transformation matrix [a b c d e f], applied to row vectors: p' = p × M.
struct Matrix {
    double a = 1, b = 0, c = 0, d = 1, e = 0, f = 0;

    // this × other: first apply this, then other.
    Matrix operator*(Matrix const& o) const {
        return {
            a * o.a + b * o.c,       a * o.b + b * o.d,
            c * o.a + d * o.c,       c * o.b + d * o.d,
            e * o.a + f * o.c + o.e, e * o.b + f * o.d + o.f,
        };
    }

    static bool fromArray(QPDFObjectHandle const& array, Matrix& m) {
        if (!array.isArray() || array.getArrayNItems() != 6) return false;
        double v[6];
        for (int i = 0; i < 6; ++i) {
            if (!array.getArrayItem(i).getValueAsNumber(v[i])) return false;
        }
        m = {v[0], v[1], v[2], v[3], v[4], v[5]};
        return true;
    }
};

// Where something is drawn, relative to the coordinate space of the content that draws it.
struct Placement {
    QPDFObjGen image;
    Matrix ctm;
};

// Placements of images in a content stream, including those inside the forms it draws.
struct ContentPlacements {
    std::vector<Placement> images;
    // Images referenced by content that could not be followed (parse errors, recursion limits).
    std::set<QPDFObjGen> unknown;
};

class Analyzer {
  public:
    Resolutions run(QPDF& pdf) {
        Resolutions result;
        for (auto& page : QPDFPageDocumentHelper(pdf).getAllPages()) {
            double unit = 1;
            QPDFObjectHandle user_unit = page.getObjectHandle().getKey("/UserUnit");
            if (user_unit.isNumber()) unit = user_unit.getNumericValue();
            if (!(unit > 0)) unit = 1;

            QPDFObjectHandle resources = page.getAttribute("/Resources", false);
            ContentPlacements content;
            try {
                content = walk(page.getObjectHandle(), resources, true, 0);
            } catch (std::exception&) {
                markAll(resources, content.unknown, 0);
            }
            for (auto& og : content.unknown) result.unknown.insert(og);
            for (auto& p : content.images) {
                // The image fills the unit square; its sides end up as these vectors (in points).
                double width = std::hypot(p.ctm.a, p.ctm.b) * unit / 72.0;
                double height = std::hypot(p.ctm.c, p.ctm.d) * unit / 72.0;
                QPDFObjectHandle image = pdf.getObject(p.image);
                if (!image.isStream()) continue;
                QPDFObjectHandle dict = image.getDict();
                int w = 0, h = 0;
                if (!dict.getKey("/Width").getValueAsInt(w) || !dict.getKey("/Height").getValueAsInt(h)) {
                    continue;
                }
                if (width < 1e-4 || height < 1e-4) continue; // invisible
                double dpi = std::min(w / width, h / height);
                auto [it, inserted] = result.dpi.emplace(p.image, dpi);
                if (!inserted) it->second = std::min(it->second, dpi);
            }
        }
        return result;
    }

  private:
    std::map<QPDFObjGen, ContentPlacements> forms_;
    std::set<QPDFObjGen> in_progress_;

    class Callbacks: public QPDFObjectHandle::ParserCallbacks {
      public:
        Callbacks(Analyzer& analyzer, QPDFObjectHandle resources, int depth, ContentPlacements& out) :
            analyzer_(analyzer),
            resources_(std::move(resources)),
            depth_(depth),
            out_(out) {}

        void handleObject(QPDFObjectHandle obj) override {
            if (!obj.isOperator()) {
                operands_.push_back(obj);
                if (operands_.size() > 64) operands_.erase(operands_.begin());
                return;
            }
            std::string op = obj.getOperatorValue();
            if (op == "q") {
                stack_.push_back(ctm_);
            } else if (op == "Q") {
                if (!stack_.empty()) {
                    ctm_ = stack_.back();
                    stack_.pop_back();
                }
            } else if (op == "cm" && operands_.size() >= 6) {
                double v[6];
                bool ok = true;
                for (int i = 0; i < 6; ++i) {
                    ok = ok && operands_[operands_.size() - 6 + size_t(i)].getValueAsNumber(v[i]);
                }
                if (ok) ctm_ = Matrix{v[0], v[1], v[2], v[3], v[4], v[5]} * ctm_;
            } else if (op == "Do" && !operands_.empty() && operands_.back().isName()) {
                draw(operands_.back().getName());
            }
            operands_.clear();
        }

        void handleEOF() override {}

      private:
        void draw(std::string const& name) {
            QPDFObjectHandle xobjects = resources_.isDictionary() ? resources_.getKey("/XObject") : QPDFObjectHandle::newNull();
            if (!xobjects.isDictionary()) return;
            QPDFObjectHandle xobject = xobjects.getKey(name);
            if (!xobject.isStream()) return;
            QPDFObjectHandle dict = xobject.getDict();
            if (dict.getKey("/Subtype").isNameAndEquals("/Image")) {
                out_.images.push_back({xobject.getObjGen(), ctm_});
            } else if (dict.getKey("/Subtype").isNameAndEquals("/Form")) {
                Matrix matrix;
                Matrix::fromArray(dict.getKey("/Matrix"), matrix);
                ContentPlacements const& form = analyzer_.form(xobject, resources_, depth_ + 1);
                Matrix to_here = matrix * ctm_;
                for (auto const& p : form.images) out_.images.push_back({p.image, p.ctm * to_here});
                out_.unknown.insert(form.unknown.begin(), form.unknown.end());
            }
        }

        Analyzer& analyzer_;
        QPDFObjectHandle resources_;
        int depth_;
        ContentPlacements& out_;
        std::vector<QPDFObjectHandle> operands_;
        std::vector<Matrix> stack_;
        Matrix ctm_;
    };

    ContentPlacements walk(QPDFObjectHandle content, QPDFObjectHandle resources, bool is_page, int depth) {
        ContentPlacements out;
        Callbacks callbacks(*this, resources, depth, out);
        if (is_page) {
            QPDFPageObjectHelper(content).parseContents(&callbacks);
        } else {
            QPDFObjectHandle::parseContentStream(content, &callbacks);
        }
        return out;
    }

    ContentPlacements const& form(QPDFObjectHandle form, QPDFObjectHandle const& parent_resources, int depth) {
        QPDFObjGen og = form.getObjGen();
        auto found = forms_.find(og);
        if (found != forms_.end()) return found->second;

        QPDFObjectHandle resources = form.getDict().getKey("/Resources");
        // Forms without resources use their parent's (deprecated, but it happens). Their
        // placements then depend on the caller, so they are not cached.
        bool inherits = !resources.isDictionary();
        if (inherits) resources = parent_resources;

        ContentPlacements result;
        if (depth > 24 || in_progress_.count(og)) {
            markAll(resources, result.unknown, 0);
        } else {
            in_progress_.insert(og);
            try {
                result = walk(form, resources, false, depth);
            } catch (std::exception&) {
                result = ContentPlacements();
                markAll(resources, result.unknown, 0);
            }
            in_progress_.erase(og);
        }
        if (inherits) {
            scratch_.push_back(std::move(result));
            return scratch_.back();
        }
        return forms_[og] = std::move(result);
    }

    // Marks every image reachable through these resources as having an unknown placement.
    void markAll(QPDFObjectHandle resources, std::set<QPDFObjGen>& out, int depth) {
        if (depth > 8 || !resources.isDictionary()) return;
        QPDFObjectHandle xobjects = resources.getKey("/XObject");
        if (!xobjects.isDictionary()) return;
        for (auto const& key : xobjects.getKeys()) {
            QPDFObjectHandle x = xobjects.getKey(key);
            if (!x.isStream()) continue;
            QPDFObjectHandle subtype = x.getDict().getKey("/Subtype");
            if (subtype.isNameAndEquals("/Image")) {
                out.insert(x.getObjGen());
            } else if (subtype.isNameAndEquals("/Form")) {
                markAll(x.getDict().getKey("/Resources"), out, depth + 1);
            }
        }
    }

    std::deque<ContentPlacements> scratch_; // results of forms that inherit resources
};

} // namespace

Resolutions findImageResolutions(QPDF& pdf) {
    return Analyzer().run(pdf);
}

} // namespace smol
