#!/bin/bash
# Builds the RDKAFKA synthetic-boundary ownership harness against a source
# tree with ASan/UBSan and runs every test in its own process (macOS only).
#
#   tests/ownership/run.sh <repo-root> <fixed|baseline>
#
# <repo-root> provides rdkafka/ (plugin sources, bundled 4D Plugin API,
# vendored headers). The harness itself always comes from
# this script's directory, so the SAME harness can be run against an
# immutable baseline (git archive of the base SHA) and against the fixed tree.
#
# The vendored static libraries are i386/x86_64 only, so the harness is
# built for x86_64 (Rosetta on Apple silicon), matching the plugin's
# shipped Intel slice.
#
# In "fixed" mode every test must pass. In "baseline" mode the tests named
# in EXPECTED_BASELINE_FAILURES must fail and every other test (the
# controls) must pass; anything else is a harness or model error.
set -euo pipefail

SRC=$(cd "$1/rdkafka" && pwd)
MODE=$2
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

EXPECTED_BASELINE_FAILURES="
defect_picture_fromfile_ownership
defect_picture_setbytes_leak
defect_picture_createcopy_ownership
defect_picture_grayscale_owner_leak
defect_picture_getsize_owner_leak
defect_picture_thumbnail_owner_leak
"

ARCH="-arch x86_64"
SAN="$ARCH -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined"
API="$SRC/4D Plugin API"
# Same prefix header as the Xcode target (GCC_PREFIX_HEADER).
INC=(-include "$SRC/4D Plugin_Prefix.pch" -I "$API" -I "$API/Classes" -I "$SRC" -I "$SRC/include/libjson" -I "$SRC/include/librdkafka")
# The Xcode target sets no C++ dialect; 4DPlugin.cpp needs pre-C++11 string
# literal rules ("%"PRIu64"").
PLUGIN_STD=-std=gnu++98

objs=()
cc() { # <file> [extra flags...]
    local file=$1; shift
    local o="$OUT/$(basename "$file").o"
    xcrun clang $SAN -w -x objective-c++ "$@" -c "$file" -o "$o"
    objs+=("$o")
}

cc "$API/4DPluginAPI.c" "${INC[@]}" $PLUGIN_STD
for f in "$API"/Classes/*.cpp; do
    cc "$f" "${INC[@]}" $PLUGIN_STD
done
cc "$SRC/4DPlugin.cpp" "${INC[@]}" $PLUGIN_STD -fno-objc-arc
cc "$HERE/rdkafka_stub.cpp" -I "$SRC/include/librdkafka" -std=c++17
cc "$HERE/libjson_stub.cpp" -I "$SRC/include/libjson" -std=c++17
cc "$HERE/engine_harness.mm" "${INC[@]}" -std=c++17 -fno-objc-arc

# librdkafka (with its ssl/crypto/z dependencies) and libjson are replaced at
# the C API boundary by rdkafka_stub.cpp and libjson_stub.cpp: the vendored
# a/libjson.a targets the legacy GNU libstdc++ ABI and cannot be linked here.
xcrun clang++ $SAN "${objs[@]}" -framework AppKit -framework Foundation -framework CoreFoundation -framework CoreServices -framework Carbon -o "$OUT/harness"

export ASAN_OPTIONS=abort_on_error=0:halt_on_error=1
export UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1

bad=0
for t in $("$OUT/harness" --list); do
    if "$OUT/harness" "$t" >"$OUT/$t.log" 2>&1; then got=pass; else got=fail; fi
    expect=pass
    if [ "$MODE" = baseline ] && grep -qx "$t" <<<"$EXPECTED_BASELINE_FAILURES"; then expect=fail; fi
    if [ "$got" = "$expect" ]; then status=OK; else status=UNEXPECTED; bad=1; fi
    printf '%-12s %-5s (expected %-4s) %s\n' "$status" "$got" "$expect" "$t"
    if [ "$got" = fail ]; then sed 's/^/    | /' "$OUT/$t.log"; fi
    # A sanitizer report or engine/stub violation is only acceptable as a
    # named baseline failure.
    if [ "$expect" = pass ] && grep -qE 'ERROR: AddressSanitizer|runtime error:|ENGINE VIOLATION|RDKAFKA STUB VIOLATION|LIBJSON STUB VIOLATION' "$OUT/$t.log"; then
        echo "UNEXPECTED   sanitizer/engine violation in $t"; bad=1
    fi
done

if [ $bad -ne 0 ]; then echo "RESULT ($MODE): FAILED"; exit 1; fi
echo "RESULT ($MODE): all outcomes as expected"
