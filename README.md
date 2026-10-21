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

## Install

smol-pdf needs macOS 14 or later, on Apple silicon or Intel.

### With Homebrew

```sh
brew tap jansim/smol-pdf https://github.com/jansim/smol-pdf
brew install --cask jansim/smol-pdf/smol-pdf
```

This puts smol-pdf in Applications and the command-line tool `smolpdf` on your `PATH`. Use the full
name `jansim/smol-pdf/smol-pdf` the first time: installing a cask by its full name is how you tell
Homebrew to trust it. Homebrew 6 and later won't load casks from other taps until you trust them.
After that, `brew upgrade` updates smol-pdf along with everything else.
`brew uninstall --cask --zap smol-pdf` removes it, including its settings and history.

### By hand

Download `smol-pdf-<version>-macos-universal.zip` from the
[latest release](https://github.com/jansim/smol-pdf/releases/latest), unzip it and move smol-pdf to
Applications. The command-line tool is inside the app (see [Command line](#command-line)). It is also
in the release on its own, as `smol-pdf-<version>-macos-universal-cli.tar.gz`.

### "Apple could not verify smol-pdf"

Apple only notarizes apps for members of its paid developer program, so smol-pdf is signed ad hoc
and not notarized. When you download it with a browser, macOS refuses to open it the first time.
To open it anyway:

- Try to open it once. Then go to **System Settings → Privacy & Security**, click **Open Anyway** next
  to the message about smol-pdf, and confirm. Or:
- Remove the quarantine flag that the browser put on the download:
  `xattr -dr com.apple.quarantine /Applications/smol-pdf.app` (and
  `xattr -d com.apple.quarantine smolpdf` for the separate command-line tool).

The Homebrew cask removes the quarantine flag for you after installing. If you would rather not
trust a prebuilt app, build it from source.

## Build

Requires macOS 14 or later and Xcode 16 or later (Swift 6 toolchain). The C/C++ libraries are
git submodules, so clone with `--recursive` (or run `git submodule update --init` in an existing clone).

```sh
scripts/build-app.sh && open build/smol-pdf.app
```

`ARCHS="arm64 x86_64" scripts/build-app.sh` builds universal binaries. Publishing a GitHub release
(or running the Release workflow by hand with a draft's tag) attaches the zipped app and the
command-line tool, built that way, to the release. Once it is the latest release, the workflow also
updates the Homebrew cask (`Casks/smol-pdf.rb`; this repository is the tap) with a commit to the
default branch. Release tags are `v` and the version, e.g. `v1.2`.

For development, `swift run SmolPDFApp` starts the app without bundling, and `swift test` runs the
engine tests.

To update a library, check out a newer tag in its submodule (e.g.
`git -C Vendor/CQPDF/qpdf fetch --depth 1 origin tag v12.3.0 && git -C Vendor/CQPDF/qpdf checkout v12.3.0`),
update the version in the config headers next to it if they mention one, and check `Package.swift`'s
file lists against the library's own build files.

## Command line

The Homebrew cask puts `smolpdf` on your `PATH`. Otherwise it is at
`/Applications/smol-pdf.app/Contents/Resources/smolpdf` (or use `swift run smolpdf …` in a checkout):

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
| `Vendor/` | qpdf, mozjpeg and libdeflate as submodules, with the config headers their builds would generate |
| `Sources/SmolPDFApp` | SwiftUI app |
| `Sources/smolpdf` | Command-line tool |
| `Tests/SmolPDFCoreTests` | Engine tests using generated PDFs |
| `scripts/` | App bundling and icon generation |
| `Casks/` | Homebrew cask (this repository is also the tap) |

## Known limitations

- Fonts are not subsetted; a fully embedded font stays fully embedded.
- JPEG 2000, JBIG2 and CCITT images already in a file are left as they are, and nothing is stored
  as JPEG 2000. JBIG2 is lossless only (no symbol coding).
- Grayscale leaves spot colors (Separation, DeviceN) and Lab colors as they are.
- Files that qpdf can't repair can't be compressed.
- CMYK images are only re-encoded as JPEG when they were JPEGs already, to keep their colors exact.

## Licenses

smol-pdf bundles qpdf (Apache 2.0), mozjpeg (IJG and BSD-3-Clause) and libdeflate (MIT). Their
license files are in their submodules under `Vendor/` and are copied into the app bundle.
