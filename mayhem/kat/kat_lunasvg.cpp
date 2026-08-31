// mayhem/kat/kat_lunasvg.cpp — known-answer-test probe, built by mayhem/build.sh against the CLEAN
// (unsanitized, normal-flags) library build and RUN by mayhem/test.sh.
//
// lunasvg ships no test suite of its own (no tests/, no CTest target — checked: none exists
// upstream), so mayhem/test.sh has nothing of the project's own to run. Per the net-new worker
// brief §4 ("REQUIRED: a known-answer assertion through a dynamically linked binary"), this probe
// takes the place of that suite: fixed SVG input -> exact asserted output (parsed dimensions, a raw
// attribute string, an element lookup, and a rendered pixel's exact ARGB32-premultiplied value).
//
// Every check prints an unconditional ASSERT_OK/ASSERT_FAIL line — never behind an `[ -f ... ]`-style
// guard — so mayhem/test.sh's line-count oracle degrades correctly (to "missing", i.e. FAILED) if the
// binary is neutered (e.g. _exit()'d before any assertion runs) rather than silently reporting zero
// tests as a pass.
#include <lunasvg.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {

int g_failures = 0;

void check(bool ok, const char* name, const char* detail) {
    if (ok) {
        std::printf("ASSERT_OK: %s\n", name);
    } else {
        std::printf("ASSERT_FAIL: %s: %s\n", name, detail);
        ++g_failures;
    }
}

} // namespace

int main() {
    // 1) A syntactically bogus, non-SVG input MUST fail to parse (nullptr), never crash/succeed.
    auto garbage = lunasvg::Document::loadFromData("this is not xml at all {{{", 26);
    check(garbage == nullptr, "garbage-input-rejected", "loadFromData(garbage) did not return nullptr");

    // 2) A minimal, well-formed 10x10 opaque-red square with a known id and viewBox.
    static const char kSvg[] =
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\" viewBox=\"0 0 10 10\">"
        "<rect id=\"r1\" width=\"10\" height=\"10\" fill=\"#ff0000\"/>"
        "</svg>";
    auto document = lunasvg::Document::loadFromData(kSvg, sizeof(kSvg) - 1);
    check(document != nullptr, "kat-svg-parses", "loadFromData(kSvg) returned nullptr");
    if (!document) {
        std::printf("CTRF_ABORT\n");
        return 1;
    }

    document->updateLayout();

    // 3) Intrinsic size comes straight from the width/height attributes above.
    char detail[128];
    bool sizeOk = document->width() == 10.0f && document->height() == 10.0f;
    std::snprintf(detail, sizeof(detail), "got width=%g height=%g, want 10x10",
                  static_cast<double>(document->width()), static_cast<double>(document->height()));
    check(sizeOk, "kat-intrinsic-size", detail);

    // 4) getAttribute returns the raw, unnormalized attribute string.
    auto root = document->documentElement();
    bool viewBoxOk = root && root.getAttribute("viewBox") == "0 0 10 10";
    std::snprintf(detail, sizeof(detail), "got viewBox=\"%s\", want \"0 0 10 10\"",
                  root ? root.getAttribute("viewBox").c_str() : "(null root)");
    check(viewBoxOk, "kat-root-viewbox-attr", detail);

    // 5) getElementById resolves the rect by its id, and its own raw attribute round-trips exactly.
    auto rect = document->getElementById("r1");
    bool fillOk = rect && rect.getAttribute("fill") == "#ff0000";
    std::snprintf(detail, sizeof(detail), "got element=%s fill=\"%s\", want fill=\"#ff0000\"",
                  rect ? "found" : "null", rect ? rect.getAttribute("fill").c_str() : "(n/a)");
    check(fillOk, "kat-get-element-by-id", detail);

    // 6) Rendering the fully-opaque red square into a 10x10 bitmap: the CENTER pixel (safely inside
    //    the fill, away from any edge antialiasing) must be exactly opaque red in lunasvg's documented
    //    pixel format — 32-bit premultiplied ARGB, native-endian (0xAARRGGBB), i.e. 0xFFFF0000 for a
    //    fully-opaque red pixel on a little-endian host.
    auto bitmap = document->renderToBitmap(10, 10);
    bool bitmapOk = false;
    uint32_t centerPixel = 0;
    if (!bitmap.isNull() && bitmap.width() == 10 && bitmap.height() == 10) {
        const uint8_t* row = bitmap.data() + static_cast<std::size_t>(5) * bitmap.stride();
        std::memcpy(&centerPixel, row + 5 * 4, sizeof(centerPixel));
        bitmapOk = centerPixel == 0xFFFF0000u;
    }
    std::snprintf(detail, sizeof(detail), "center pixel=0x%08X, want 0xFFFF0000 (opaque red, premultiplied ARGB)",
                  centerPixel);
    check(bitmapOk, "kat-render-pixel", detail);

    std::printf("KAT_DONE failures=%d\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
