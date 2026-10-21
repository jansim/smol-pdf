#!/bin/sh
# Builds build/smol-pdf.app (and the smolpdf command-line tool) in release mode.
# ARCHS="arm64 x86_64" builds universal binaries (default: this Mac's architecture only),
# VERSION=1.2.3 sets the app's version.
set -euo pipefail
cd "$(dirname "$0")/.."

# One release build per architecture, merged with lipo; stripped of debug and local symbols
# (which voids their ad-hoc signature, so they are signed again).
ARCHS="${ARCHS:-$(uname -m)}"
OUT=build/bin
rm -rf "$OUT"
mkdir -p "$OUT"
for product in SmolPDFApp smolpdf; do
    slices=""
    for arch in $ARCHS; do
        swift build -c release --arch "$arch" --product "$product"
        slices="$slices $(swift build -c release --arch "$arch" --show-bin-path)/$product"
    done
    lipo -create $slices -output "$OUT/$product"
    strip -S -x "$OUT/$product"
    codesign --force --sign - "$OUT/$product"
done

APP=build/smol-pdf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/SmolPDFApp" "$APP/Contents/MacOS/"
cp "$OUT/smolpdf" "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Licenses of the bundled libraries.
mkdir -p "$APP/Contents/Resources/Licenses"
cp Vendor/CQPDF/qpdf/LICENSE.txt "$APP/Contents/Resources/Licenses/qpdf-LICENSE.txt"
cp Vendor/CQPDF/qpdf/NOTICE.md "$APP/Contents/Resources/Licenses/qpdf-NOTICE.md"
cp Vendor/CJPEG/mozjpeg/LICENSE.md "$APP/Contents/Resources/Licenses/mozjpeg-LICENSE.md"
cp Vendor/CJPEG/mozjpeg/README.ijg "$APP/Contents/Resources/Licenses/mozjpeg-README.ijg"
cp Vendor/CDeflate/libdeflate/COPYING "$APP/Contents/Resources/Licenses/libdeflate-COPYING.txt"
codesign --force --sign - "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/SmolPDFApp"))"
