// mayhem/fuzz_lunasvg.cpp — libFuzzer harness for lunasvg.
//
// lunasvg is an SVG rendering library: it parses an SVG/XML document from raw bytes and can then
// lay it out, query it, and rasterize it. Untrusted SVG parsing is the classic attack surface for
// this class of library, so the harness feeds the fuzzer's raw bytes straight into the public
// `lunasvg::Document::loadFromData(const char*, size_t)` entry point and then exercises layout,
// DOM query, and rendering — the parts of the API surface most likely to be reached by a real
// embedder (browsers/renderers typically parse, then query the DOM, then rasterize).
//
// No file I/O — the harness only reads the bytes libFuzzer hands it (SPEC §6.2 item 13 / the
// net-new worker brief §3: Mayhem runs the target from its own writable cwd, not /mayhem, so any
// relative-path file read here would fail on every input).
//
// Document::loadFromData returns a std::unique_ptr<Document> already — no manual new/delete here;
// the unique_ptr destructor frees everything when `document` goes out of scope, including on the
// early `return 0` paths below.
#include <lunasvg.h>

#include <cstddef>
#include <cstdint>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    auto document = lunasvg::Document::loadFromData(reinterpret_cast<const char*>(data), size);
    if (!document) {
        return 0;
    }

    // Force a full layout pass (element positions, viewBox resolution, CSS cascade, <use>/<symbol>
    // expansion) — a document that merely parses without laying out would leave a large fraction of
    // the library's logic (and its bugs) unreached.
    document->updateLayout();

    // Touch a couple of read-only DOM query paths that a real embedder commonly calls after parsing.
    (void)document->boundingBox();
    (void)document->documentElement();

    // Rasterize into a FIXED small bitmap. Passing explicit positive width/height means
    // Document::renderToBitmap never falls back to the document's own (attacker-controlled)
    // intrinsic width/height/viewBox to size the allocation — so a hostile `width="999999999"` can't
    // turn this harness into an allocation-size oracle / OOM generator instead of a parser/renderer
    // fuzzer. The bitmap itself is on the stack-owned RAII `Bitmap` type; no manual free needed.
    auto bitmap = document->renderToBitmap(64, 64);
    (void)bitmap;

    return 0;
}
