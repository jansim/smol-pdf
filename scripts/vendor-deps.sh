#!/bin/bash
# Refreshes the vendored C/C++ dependencies in Sources/CQPDF and Sources/CJPEG.
#
# The sources are committed, so a normal build needs neither this script nor network access.
# Run it only to move to a new upstream version: bump the tags below, run it, build, test, commit.
#
#   qpdf    (Apache 2.0)        PDF object model, stream decoding, writer, encryption
#   mozjpeg (IJG/BSD-3-Clause)  libjpeg-turbo fork with trellis quantisation (smaller JPEGs);
#                               built without SIMD so it compiles as a plain SwiftPM C target
#   libdeflate (MIT)            Deflate compressor that beats zlib -9, used for every Flate stream we write
set -euo pipefail
cd "$(dirname "$0")/.."

QPDF_TAG=v12.2.0
MOZJPEG_TAG=v4.1.5
LIBDEFLATE_TAG=v1.25

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -c advice.detachedHead=false clone -q --depth 1 --branch "$QPDF_TAG" https://github.com/qpdf/qpdf.git "$WORK/qpdf"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$MOZJPEG_TAG" https://github.com/mozilla/mozjpeg.git "$WORK/mozjpeg"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$LIBDEFLATE_TAG" https://github.com/ebiggers/libdeflate.git "$WORK/libdeflate"

# --- mozjpeg ---------------------------------------------------------------------------------
JPEG=Sources/CJPEG
rm -rf "$JPEG"
mkdir -p "$JPEG/include"
# Library sources (JPEG_SOURCES in upstream CMakeLists.txt), arithmetic decoding, no SIMD.
for f in jcapimin jcapistd jccoefct jccolor jcdctmgr jchuff jcext jcicc jcinit jcmainct jcmarker \
    jcmaster jcomapi jcparam jcphuff jcprepct jcsample jctrans jdapimin jdapistd jdatadst jdatasrc \
    jdcoefct jdcolor jddctmgr jdhuff jdicc jdinput jdmainct jdmarker jdmaster jdmerge jdphuff \
    jdpostct jdsample jdtrans jerror jfdctflt jfdctfst jfdctint jidctflt jidctfst jidctint jidctred \
    jquant1 jquant2 jutils jmemmgr jmemnobs jaricom jdarith jsimd_none; do
    cp "$WORK/mozjpeg/$f.c" "$JPEG/"
done
# Fragments #included by other sources; Package.swift excludes them from compilation.
mkdir -p "$JPEG/fragments"
for f in jccolext jdcol565 jdcolext jdmrg565 jdmrgext jstdhuff; do
    cp "$WORK/mozjpeg/$f.c" "$JPEG/fragments/"
done
for f in "$WORK"/mozjpeg/*.h; do
    case "$(basename "$f")" in
        jpeglib.h | jmorecfg.h | jerror.h) cp "$f" "$JPEG/include/" ;;
        cderror.h | cdjpeg.h | cmyk.h | tjutil.h | transupp.h | turbojpeg.h) ;;
        *) cp "$f" "$JPEG/" ;;
    esac
done
cp "$WORK/mozjpeg/LICENSE.md" "$WORK/mozjpeg/README.ijg" "$JPEG/"
cp scripts/vendor/jconfig.h "$JPEG/include/"
cp scripts/vendor/jconfigint.h scripts/vendor/jversion.h "$JPEG/"
cp scripts/vendor/CJPEG.modulemap "$JPEG/include/module.modulemap"

# --- qpdf ------------------------------------------------------------------------------------
QPDF=Sources/CQPDF
rm -rf "$QPDF"
mkdir -p "$QPDF/libqpdf" "$QPDF/include"
cp -R "$WORK/qpdf/include/qpdf" "$QPDF/include/"
cp -R "$WORK/qpdf/libqpdf/qpdf" "$WORK/qpdf/libqpdf/sph" "$QPDF/libqpdf/"
cp "$WORK"/qpdf/libqpdf/*.cc "$WORK"/qpdf/libqpdf/*.c "$QPDF/libqpdf/"
# Not needed: other crypto providers, and the command-line job layer.
rm -f "$QPDF"/libqpdf/QPDFCrypto_gnutls.cc "$QPDF"/libqpdf/QPDFCrypto_openssl.cc \
    "$QPDF"/libqpdf/qpdf/QPDFCrypto_gnutls.hh "$QPDF"/libqpdf/qpdf/QPDFCrypto_openssl.hh \
    "$QPDF"/libqpdf/QPDFJob*.cc "$QPDF"/libqpdf/qpdfjob-c.cc "$QPDF"/libqpdf/QPDFArgParser.cc \
    "$QPDF"/libqpdf/qpdf/qpdf-config.h.in
cp "$WORK/qpdf/LICENSE.txt" "$WORK/qpdf/NOTICE.md" "$QPDF/"
cp scripts/vendor/qpdf-config.h "$QPDF/libqpdf/qpdf/"
cp scripts/vendor/CQPDF.modulemap "$QPDF/include/module.modulemap"

# --- libdeflate (compression only) ------------------------------------------------------------
DEFLATE=Sources/CDeflate
rm -rf "$DEFLATE"
mkdir -p "$DEFLATE/include" "$DEFLATE/lib/x86" "$DEFLATE/lib/arm"
cp "$WORK/libdeflate/libdeflate.h" "$DEFLATE/include/"
cp "$WORK/libdeflate/common_defs.h" "$WORK/libdeflate/COPYING" "$DEFLATE/"
cp "$WORK"/libdeflate/lib/{deflate_compress.c,zlib_compress.c,adler32.c,utils.c} "$DEFLATE/lib/"
cp "$WORK"/libdeflate/lib/*.h "$DEFLATE/lib/"
cp "$WORK"/libdeflate/lib/x86/{cpu_features.c,*.h} "$DEFLATE/lib/x86/"
cp "$WORK"/libdeflate/lib/arm/{cpu_features.c,*.h} "$DEFLATE/lib/arm/"
cp scripts/vendor/CDeflate.modulemap "$DEFLATE/include/module.modulemap"

echo "Vendored qpdf $QPDF_TAG, mozjpeg $MOZJPEG_TAG and libdeflate $LIBDEFLATE_TAG"
