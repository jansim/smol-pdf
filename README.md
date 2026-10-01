# smol-pdf

A small native macOS app for shrinking PDF files, inspired by PDF Squeezer.

Drop a PDF onto the window or the Dock icon, pick a compression profile and press **Compress**.
The window shows the original next to the compressed file, with both sizes and how much was saved.
Earlier files are one click away in the history sidebar.

## Features

- **Profiles**: Lossless, Low, Medium, High, Maximum, plus your own custom profiles
  (image quality, maximum resolution, 1-bit scans, grayscale, and removing metadata, editing data,
  annotations, bookmarks, attachments and JavaScript).
- **Each image in the format that suits it**: photos as JPEG, screenshots and diagrams losslessly
  with a palette, black-and-white scans as 1-bit JBIG2, all at the resolution they are actually
  shown at. See [How it works](#how-it-works).
- **Lossless really is lossless**: not a single pixel changes, yet files usually still get smaller.
- **Text stays text**: only images are re-encoded, so text stays sharp and searchable.
- **Keeps the original** when compression wouldn't make the file smaller.
- **Password-protected PDFs**: unlock them in the app; the result keeps the same password.
- **Output**: next to the original with a suffix, into a folder, or replace the original
  (the original goes to the Trash).
- **Before and after**: the original and the result side by side with their names and sizes.
  Select either one and press Space to Quick Look it (even when the original is in the Trash),
  or drag it out like any file.
- **History**: every compressed file is listed in the sidebar; select one to show it again.
- **Compare**: before and after side by side, with scrolling and zoom kept in sync.
- **Command-line tool** `smolpdf` with the same engine, for batches and folders.

## Build

Requires macOS 14 or later and Xcode 16 or later (Swift 6 toolchain).

```sh
scripts/build-app.sh && open build/smol-pdf.app
```

For development, `swift run SmolPDFApp` starts the app without bundling, and `swift test` runs the
engine tests.

## Command line

The CLI is bundled at `smol-pdf.app/Contents/Resources/smolpdf` (or `swift run smolpdf …`):

```sh
smolpdf -p high ~/Documents/scans          # a folder, recursively
smolpdf -q 50 -r 120 -g report.pdf          # custom quality, resolution, grayscale
smolpdf -p high -x attachments,javascript -v in.pdf   # strip extras, show what changed
smolpdf -o ~/Desktop/small *.pdf            # write into a folder
smolpdf --help
```

## How it works

The engine (`Sources/SmolPDFEngine`, C++) rewrites the PDF with [qpdf](https://github.com/qpdf/qpdf).
Text, fonts and vector graphics are kept as they are. For every image it makes several
candidate encodings and keeps the smallest, including the original; lossless forms win when they
are within 10% of a lossy one, since they stay sharp.

| Candidate | When |
| --- | --- |
| Flate with PNG predictors chosen per row ([libdeflate](https://github.com/ebiggers/libdeflate)) | always |
| Fewer bits per sample, a palette, or true grayscale | when that is exact (or, for gray, within JPEG noise in lossy profiles) |
| JBIG2 (lossless generic region) and CCITT Group 4 | 1-bit images and masks |
| The original JPEG with optimized Huffman tables and progressive scans | JPEGs (no pixel changes) |
| JPEG at the profile's quality ([mozjpeg](https://github.com/mozilla/mozjpeg)) | photographic images, lossy profiles |
| Downsampled to the profile's resolution | lossy profiles, images shown sharper than that |
| 1-bit, thresholded | black-and-white scans, when enabled |

The resolution of an image is how it is actually drawn: the engine follows the page content
(including nested forms) to find the largest size each image is shown at. Black-and-white images
are never downsampled: as 1-bit images they are smaller and sharper at full resolution.

After the images, every other stream (page content, fonts, ...) is recompressed when that helps,
identical streams (say, a font embedded once per page) are stored once, unused resources are
dropped, and the file is written with object streams. Encryption is kept as it was.

Grayscale converts images the same way, and rewrites the colors of text and vector graphics
(color operators, color spaces, palettes and shadings) to their gray equivalents.

Set `SMOL_DEBUG=1` to see every candidate considered for each image on stderr.

Code layout:

| Path | Contents |
| --- | --- |
| `Sources/SmolPDFCore` | Compression API, profiles, output naming (no UI) |
| `Sources/SmolPDFEngine` | The compression engine (C++ with a C interface) |
| `Sources/CQPDF`, `CJPEG`, `CDeflate` | Vendored qpdf, mozjpeg and libdeflate (`scripts/vendor-deps.sh` updates them) |
| `Sources/SmolPDFApp` | SwiftUI app |
| `Sources/smolpdf` | Command-line tool |
| `Tests/SmolPDFCoreTests` | Engine tests using generated PDFs |
| `scripts/` | App bundling and icon generation |

## Known limitations

- Fonts are not subsetted; a fully embedded font stays fully embedded.
- JPEG 2000, JBIG2 and CCITT images already in a file are left as they are, and nothing is stored
  as JPEG 2000. JBIG2 is lossless only (no symbol coding).
- Grayscale leaves spot colors (Separation, DeviceN) and Lab colors as they are.
- Files that qpdf can't repair can't be compressed.
- CMYK images are only re-encoded as JPEG when they were JPEGs already, to keep their colors exact.

## Licenses

smol-pdf bundles qpdf (Apache 2.0), mozjpeg (IJG and BSD-3-Clause) and libdeflate (MIT). Their
license files are in their folders under `Sources/` and are copied into the app bundle.
