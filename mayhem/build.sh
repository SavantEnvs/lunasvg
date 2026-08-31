#!/usr/bin/env bash
#
# mayhem/build.sh — build lunasvg's fuzz harness + KAT oracle probe.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — see the base ENV for the exact
# values (CC, CXX, LIB_FUZZING_ENGINE, SANITIZER_FLAGS, DEBUG_FLAGS, STANDALONE_FUZZ_MAIN, SRC).
#
# lunasvg is a self-contained CMake C++17 library (its only dependency, plutovg, is vendored
# in-tree under plutovg/ — no network fetch at configure time, so nothing extra is needed for the
# air-gapped re-run). It ships no test suite of its own, so the "test build" step here is the KAT
# probe under mayhem/kat/ (see mayhem/test.sh) rather than an upstream test runner.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ---------------------------------------------------------------------------------------------
# 1) Build the library TWICE, into separate CMake build dirs — no clean/stash dance needed since
#    each build directory is self-contained (§6 "the dual build is usually free").
#
#    build-fuzz/  — SANITIZED: $SANITIZER_FLAGS + $DEBUG_FLAGS (DWARF < 4) + -fsanitize=fuzzer-no-link
#                   appended UNCONDITIONALLY (even when SANITIZER_FLAGS is empty) so the LIBRARY
#                   itself — not just the harness translation unit — carries SanitizerCoverage
#                   instrumentation. Without this the fuzz targets build and iterate but record 0
#                   edges in Mayhem, because $LIB_FUZZING_ENGINE only instruments the harness TU.
#    build-oracle/ — CLEAN: the project's normal flags, no sanitizer, no -gdwarf-3 — an honest
#                    oracle that won't false-fail on benign UB the fuzz build is designed to catch.
# ---------------------------------------------------------------------------------------------
# -fno-sanitize=nonnull-attribute: plutovg's font-face cache (plutovg-font.c,
# plutovg_font_face_cache_get) calls bsearch(key, cache->entries, cache->size, ...) even when the
# cache is EMPTY (cache->size==0, cache->entries==NULL) — the zero-length-buffer idiom flagged in the
# field notes. glibc declares bsearch's base-pointer argument __nonnull, so UBSan's nonnull-attribute
# check fires on every text-bearing SVG in this minimal container (no system fonts, so the cache is
# always empty on first lookup) even though bsearch never dereferences a NULL base when nmemb==0 —
# confirmed by tripping on the harmless `text.svg` seed during smoke-testing, aborting the process
# before a single byte of the actual input is rendered. Left halting, this starves the fuzzer of
# coverage on the entire text/font code path (SPEC field notes: "a halting UBSan check can silently
# starve a target of coverage"). Relax ONLY this one check; keep ASan and the rest of UBSan halting.
FUZZ_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=nonnull-attribute"
FUZZ_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=nonnull-attribute"

# NB: no -DCMAKE_BUILD_TYPE here on purpose. Setting one (e.g. RelWithDebInfo) makes CMake append
# CMAKE_CXX_FLAGS_<CONFIG> (which includes its own plain `-g`) AFTER our CMAKE_CXX_FLAGS on the
# compile line, which would silently re-emit DWARF-5 and undo $DEBUG_FLAGS's `-gdwarf-3`. Leaving
# the build type unset means our explicit flags are the only ones in play.
cmake -B build-fuzz -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FUZZ_C_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_CXX_FLAGS" \
  -DBUILD_SHARED_LIBS=OFF -DLUNASVG_BUILD_EXAMPLES=OFF
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target lunasvg

cmake -B build-oracle -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DLUNASVG_BUILD_EXAMPLES=OFF
cmake --build build-oracle -j"$MAYHEM_JOBS" --target lunasvg

FUZZ_LIBS=("$SRC/build-fuzz/liblunasvg.a" "$SRC/build-fuzz/plutovg/libplutovg.a")
ORACLE_LIBS=("$SRC/build-oracle/liblunasvg.a" "$SRC/build-oracle/plutovg/libplutovg.a")
# plutovg links -lm and (when available) -lpthread privately (see plutovg/CMakeLists.txt); those
# link requirements don't propagate out of the static archive, so repeat them on every final link
# below that consumes these archives directly (we link with plain clang++, not through CMake).
SYS_LIBS=(-lm -lpthread)

# ---------------------------------------------------------------------------------------------
# 2) The fuzz harness: ONE target, fuzz_lunasvg (Document::loadFromData -> layout -> render).
#    Compiled once (no LLVMFuzzerTestOneInput main of its own), then linked twice:
#      /mayhem/fuzz_lunasvg             -- libFuzzer engine binary (the Mayhem target)
#      /mayhem/fuzz_lunasvg-standalone  -- $STANDALONE_FUZZ_MAIN run-once reproducer
# ---------------------------------------------------------------------------------------------
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -std=c++17 \
  -I"$SRC/include" \
  -c "$SRC/mayhem/fuzz_lunasvg.cpp" -o /tmp/fuzz_lunasvg.o

# Fleet policy: disable LeakSanitizer (proactively, not just once a leak is found) by linking in a
# TU that defines __lsan_is_turned_off() — ASan's memory-corruption checks and UBSan stay active,
# only leak detection is affected. Compiled once, linked into every binary below.
LSAN_OFF_O="/tmp/lsan_off.o"
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OFF_O"

"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
  /tmp/fuzz_lunasvg.o "$LSAN_OFF_O" "${FUZZ_LIBS[@]}" "${SYS_LIBS[@]}" \
  -o /mayhem/fuzz_lunasvg

# $STANDALONE_FUZZ_MAIN is a C file — compile it with $CC (-x c handled by its own .c extension) so
# its LLVMFuzzerTestOneInput reference keeps C linkage; a straight clang++ compile would mangle it.
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS \
  /tmp/fuzz_lunasvg.o /tmp/standalone_main.o "$LSAN_OFF_O" "${FUZZ_LIBS[@]}" "${SYS_LIBS[@]}" \
  -o /mayhem/fuzz_lunasvg-standalone

# ---------------------------------------------------------------------------------------------
# 3) The KAT oracle probe (mayhem/kat/kat_lunasvg.cpp), linked against the CLEAN build — normal
#    flags, no sanitizer, so it stays an honest functional oracle. mayhem/test.sh only RUNS this.
# ---------------------------------------------------------------------------------------------
"$CXX" -std=c++17 -O2 -g \
  -I"$SRC/include" \
  "$SRC/mayhem/kat/kat_lunasvg.cpp" "${ORACLE_LIBS[@]}" "${SYS_LIBS[@]}" \
  -o /mayhem/kat_lunasvg

# Regression guard: the KAT binary must stay dynamically linked (a KAT probe accidentally linked
# static would still pass locally but weakens nothing here — kept as a cheap sanity check that the
# oracle build didn't silently change shape).
file /mayhem/kat_lunasvg | grep -q 'dynamically linked' \
  || { echo "kat_lunasvg is not dynamically linked — regression in the oracle build" >&2; exit 1; }

echo "build.sh: built /mayhem/fuzz_lunasvg{,-standalone} and /mayhem/kat_lunasvg"
