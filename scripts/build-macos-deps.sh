#!/bin/bash
# Builds the static libraries the Xcode project links from a/, as universal
# (arm64 + x86_64) archives with libc++, from pinned source releases:
#   OpenSSL 1.1.1w  -> libcrypto.a, libssl.a
#   zlib 1.3.1      -> libz.a
#   librdkafka 0.11.1 -> librdkafka.a (SSL + Cyrus SASL, bundled LZ4;
#                     matches include/librdkafka/rdkafka.h, RD_KAFKA_VERSION
#                     0x000b01ff; the committed header differs from the tag
#                     only in doc comments and is copied over the source)
#   libjson 7.6.1   -> libjson.a (compiled with the committed include/libjson
#                     headers and JSONOptions.h, so the options match the plugin)
#
# usage: scripts/build-macos-deps.sh [output-dir]   (default: a/)
# WORK (default build/deps) holds downloads and per-arch builds; a rerun reuses them.
# Needs: Xcode command line tools, curl, make.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/a}"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
WORK="${WORK:-$ROOT/build/deps}"
MIN="${MACOSX_DEPLOYMENT_TARGET:-11.5}"
JOBS="$(sysctl -n hw.ncpu)"
ARCHS="arm64 x86_64"

OPENSSL_URL=https://www.openssl.org/source/openssl-1.1.1w.tar.gz
OPENSSL_SHA=cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8
ZLIB_URL=https://zlib.net/fossils/zlib-1.3.1.tar.gz
ZLIB_SHA=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
RDKAFKA_URL=https://github.com/confluentinc/librdkafka/archive/refs/tags/v0.11.1.tar.gz
RDKAFKA_SHA=dd035d57c8f19b0b612dd6eefe6e5eebad76f506e302cccb7c2066f25a83585e
JSON_URL=https://downloads.sourceforge.net/project/libjson/libjson_7.6.1.zip
JSON_SHA=07267a3951038ee2e02d26cc41bf8e275668c38f751240d3e78dc979182e7376

# keep Homebrew headers and libraries out of the build
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH || true
export PKG_CONFIG_LIBDIR=/nonexistent
export MACOSX_DEPLOYMENT_TARGET="$MIN"

mkdir -p "$WORK/dl" "$OUT" "$WORK/bin"
# librdkafka 0.11.1's Makefile invokes "python" (not python3)
ln -sf "$(command -v python3)" "$WORK/bin/python"
export PATH="$WORK/bin:$PATH"

# fetch <url> <sha256> <file>: download with retries, verify the checksum
fetch() {
  local f="$WORK/dl/$3" i
  if [ -f "$f" ] && echo "$2  $f" | shasum -a 256 -c - >/dev/null 2>&1; then
    return 0
  fi
  for i in 1 2 3; do
    curl -fsSL --retry 3 -o "$f.tmp" "$1" && break
    [ "$i" = 3 ] && { echo "::error::download failed: $1"; return 1; }
    echo "download $1 failed, retrying"; sleep 10
  done
  echo "$2  $f.tmp" | shasum -a 256 -c - || { echo "::error::checksum mismatch: $1"; rm -f "$f.tmp"; return 1; }
  mv "$f.tmp" "$f"
}

# unpack <archive> <dest dir>: fresh extraction into dest
unpack() {
  rm -rf "${2:?}"; mkdir -p "$2"
  case "$1" in
    *.zip) (cd "$2" && unzip -q "$WORK/dl/$1") ;;
    *) tar -xzf "$WORK/dl/$1" -C "$2" --strip-components 1 ;;
  esac
}

fetch "$OPENSSL_URL"  "$OPENSSL_SHA"  openssl-1.1.1w.tar.gz
fetch "$ZLIB_URL"     "$ZLIB_SHA"     zlib-1.3.1.tar.gz
fetch "$RDKAFKA_URL"  "$RDKAFKA_SHA"  librdkafka-0.11.1.tar.gz
fetch "$JSON_URL"     "$JSON_SHA"     libjson_7.6.1.zip

for A in $ARCHS; do
  P="$WORK/$A/prefix"
  FLAGS="-arch $A -mmacosx-version-min=$MIN -O2"
  mkdir -p "$P/lib" "$P/include"

  # zlib: configure + make libz.a, then install the archive and headers
  if [ ! -f "$P/lib/libz.a" ]; then
    echo "::group::zlib $A"
    S="$WORK/$A/zlib"; unpack zlib-1.3.1.tar.gz "$S"
    (cd "$S" && CFLAGS="$FLAGS" ./configure --static --prefix="$P" \
      && make -j"$JOBS" libz.a \
      && cp libz.a "$P/lib/" && cp zlib.h zconf.h "$P/include/")
    echo "::endgroup::"
  fi

  # OpenSSL: per-arch Configure + static libs only, then install_sw for the
  # headers and pkg-config files librdkafka's configure probes for
  if [ ! -f "$P/lib/libssl.a" ]; then
    echo "::group::openssl $A"
    S="$WORK/$A/openssl"; unpack openssl-1.1.1w.tar.gz "$S"
    (cd "$S" && ./Configure "darwin64-$A-cc" --prefix="$P" --openssldir="$P/ssl" \
        no-shared no-tests \
      && make -j"$JOBS" build_libs \
      && make install_sw)
    echo "::endgroup::"
  fi

  # librdkafka: SSL + Cyrus SASL + zlib, bundled LZ4 (--disable-lz4), as in
  # the shipped archive. configure runs compile probes, so the per-arch
  # prefix must be visible through CPPFLAGS/LDFLAGS.
  if [ ! -f "$P/lib/librdkafka.a" ]; then
    echo "::group::librdkafka $A"
    S="$WORK/$A/librdkafka"; unpack librdkafka-0.11.1.tar.gz "$S"
    # the committed header is what the plugin compiles against; it differs
    # from the v0.11.1 tag only in doc comments
    cp "$ROOT/include/librdkafka/rdkafka.h" "$S/src/rdkafka.h"
    (cd "$S" && \
      CPPFLAGS="-I$P/include" LDFLAGS="-L$P/lib" \
      CC=clang CFLAGS="$FLAGS" \
      ./configure --prefix="$P" --disable-lz4 \
      && make -j"$JOBS" -C src)
    cp "$S/src/librdkafka.a" "$P/lib/"
    echo "::endgroup::"
  fi
done

# universal archives
lipo -create "$WORK"/arm64/prefix/lib/libz.a        "$WORK"/x86_64/prefix/lib/libz.a        -output "$OUT/libz.a"
lipo -create "$WORK"/arm64/prefix/lib/libcrypto.a  "$WORK"/x86_64/prefix/lib/libcrypto.a  -output "$OUT/libcrypto.a"
lipo -create "$WORK"/arm64/prefix/lib/libssl.a     "$WORK"/x86_64/prefix/lib/libssl.a     -output "$OUT/libssl.a"
lipo -create "$WORK"/arm64/prefix/lib/librdkafka.a "$WORK"/x86_64/prefix/lib/librdkafka.a -output "$OUT/librdkafka.a"

# libjson: upstream sources, with the committed headers and JSONOptions.h laid on top
if [ ! -f "$WORK/libjson-build/libjson.a" ]; then
  echo "::group::libjson"
  unpack libjson_7.6.1.zip "$WORK/libjson-src"
  J="$WORK/libjson-src/libjson"
  cp -R "$ROOT/include/libjson/." "$J/"
  # JSON_MAP spells the key "const x"; with x = void * that is "const void *", not the
  # map's "void * const", which current libc++ rejects. "x const" is the intended type.
  sed -i "" -e 's/std::pair<const x, y>/std::pair<x const, y>/' "$J/_internal/Source/JSONDefs.h"
  grep -q 'std::pair<x const, y>' "$J/_internal/Source/JSONDefs.h"
  rm -rf "$WORK/libjson-build"; mkdir -p "$WORK/libjson-build"
  for f in "$J"/_internal/Source/*.cpp; do
    clang++ -arch arm64 -arch x86_64 -mmacosx-version-min="$MIN" -O2 -DNDEBUG -fPIC \
      -I"$J" -c "$f" -o "$WORK/libjson-build/$(basename "${f%.cpp}").o"
  done
  # Apple's libtool archives fat objects directly
  libtool -static -o "$WORK/libjson-build/libjson.a" "$WORK"/libjson-build/*.o
  echo "::endgroup::"
fi
cp "$WORK/libjson-build/libjson.a" "$OUT/libjson.a"

# every output must carry both slices
for L in libcrypto libssl libz librdkafka libjson; do
  for A in $ARCHS; do
    lipo "$OUT/$L.a" -verify_arch "$A" || { echo "::error::$L.a lacks $A"; exit 1; }
  done
  echo "$L.a: $(lipo -archs "$OUT/$L.a")"
done
