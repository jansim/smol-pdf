# smol-pdf

A small native macOS app for shrinking PDF files, inspired by PDF Squeezer.

Drop PDFs (or whole folders) onto the window or the Dock icon, pick a compression profile and
press **Compress**. Each file shows its old and new size, how much was saved, and a side-by-side
before/after comparison.

## Features

- **Profiles**: Lossless, Low, Medium, High, Maximum, plus your own custom profiles
  (image quality, maximum resolution, grayscale, removing metadata, annotations and bookmarks).
- **Batch processing**: several files are compressed in parallel.
- **Text stays text**: only images are re-encoded, so text stays sharp and searchable.
- **Keeps the original** when compression wouldn't make the file smaller.
- **Password-protected PDFs**: unlock them in the app; the result keeps the same password.
- **Output**: next to the original with a suffix, into a folder, or replace the original
  (the original goes to the Trash).
- **Compare**: before and after side by side, with scrolling and zoom kept in sync.
- **Command-line tool** `smolpdf` with the same engine.

## Build

Requires macOS 14 or later and Xcode 16 or later (Swift 6 toolchain).

```sh
./scripts/build-app.sh          # → build/smol-pdf.app
open build/smol-pdf.app
```

For development, `swift run SmolPDFApp` starts the app without bundling, and `swift test` runs the
engine tests.

## Command line

The CLI is bundled at `smol-pdf.app/Contents/Resources/smolpdf` (or `swift run smolpdf …`):

```sh
smolpdf -p high ~/Documents/scans          # a folder, recursively
smolpdf -q 50 -r 120 -g report.pdf          # custom quality, resolution, grayscale
smolpdf -o ~/Desktop/small *.pdf            # write into a folder
smolpdf --help
```

## How it works

Compression runs through PDFKit and a generated ColorSync (Quartz) filter. This is the same
mechanism as Preview's “Reduce File Size”, but with tunable JPEG quality and target resolution.
Pages are rewritten by Quartz, so text, vector graphics and links are kept, and only raster
images are downsampled and re-encoded. Grayscale uses the system “Gray Tone” filter, merged into
the same pass.

Code layout:

| Path | Contents |
| --- | --- |
| `Sources/SmolPDFCore` | Compression engine, profiles, output naming (no UI) |
| `Sources/SmolPDFApp` | SwiftUI app |
| `Sources/smolpdf` | Command-line tool |
| `Tests/SmolPDFCoreTests` | Engine tests using generated PDFs |
| `scripts/` | App bundling and icon generation |

## Known limitations

- Grayscale images are still stored as three color channels (the system filter changes the tone,
  not the color space), so grayscale saves less space than it could.
- Images smaller than 128 px are left alone.
- The Lossless profile only rewrites the file structure. It rarely helps and often keeps the original.
