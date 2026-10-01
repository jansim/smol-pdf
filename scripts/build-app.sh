#!/bin/sh
# Builds build/smol-pdf.app (and the smolpdf command-line tool) in release mode.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product SmolPDFApp
swift build -c release --product smolpdf
BIN="$(swift build -c release --show-bin-path)"

APP=build/smol-pdf.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SmolPDFApp" "$APP/Contents/MacOS/"
cp "$BIN/smolpdf" "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Licenses of the bundled libraries.
mkdir -p "$APP/Contents/Resources/Licenses"
cp Sources/CQPDF/LICENSE.txt "$APP/Contents/Resources/Licenses/qpdf-LICENSE.txt"
cp Sources/CQPDF/NOTICE.md "$APP/Contents/Resources/Licenses/qpdf-NOTICE.md"
cp Sources/CJPEG/LICENSE.md "$APP/Contents/Resources/Licenses/mozjpeg-LICENSE.md"
cp Sources/CJPEG/README.ijg "$APP/Contents/Resources/Licenses/mozjpeg-README.ijg"
cp Sources/CDeflate/COPYING "$APP/Contents/Resources/Licenses/libdeflate-COPYING.txt"
codesign --force --sign - "$APP"

echo "Built $APP"
