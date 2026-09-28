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
codesign --force --sign - "$APP"

echo "Built $APP"
