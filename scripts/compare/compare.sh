#!/bin/bash
# Compares the engine with the previous Quartz-filter implementation (macOS only).
#
#   scripts/compare/compare.sh [folder-with-pdfs]
#
# Without a folder, a generated test corpus is used (needs: pip3 install pikepdf pillow).
# Writes comparison.md and the compressed files (results/) into the folder.
set -euo pipefail
cd "$(dirname "$0")/../.."

DIR="${1:-}"
if [ -z "$DIR" ]; then
    DIR=.build/compare-corpus
    mkdir -p "$DIR"
    python3 scripts/compare/make_corpus.py "$DIR"
    cp test-document.pdf "$DIR/"
fi
SMOL_COMPARE_DIR="$(cd "$DIR" && pwd)" swift test -c release -Xswiftc -enable-testing --filter QuartzComparisonTests
echo "Report: $DIR/comparison.md"
