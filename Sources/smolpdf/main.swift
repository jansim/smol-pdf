import Foundation
import SmolPDFCore

let usage = """
usage: smolpdf [options] <file-or-folder>...

Compresses PDF files. Folders are searched recursively.

options:
  -p, --profile <name>    lossless | low | medium | high | maximum (default: medium)
  -q, --quality <0-100>   JPEG quality, overrides the profile
  -r, --resolution <dpi>  maximum image resolution, overrides the profile
  -g, --grayscale         convert to grayscale
  -b, --mono-scans        store black-and-white scans as 1-bit images
  -m, --strip-metadata    remove document metadata
  -x, --strip <items>     also remove: editing (private app data, thumbnails), annotations,
                          bookmarks, attachments, javascript, or all (comma-separated)
  -o, --output <folder>   write results into this folder
  -s, --suffix <text>     file name suffix when writing next to the original (default: -compressed)
      --replace           replace the originals (they are moved to the Trash)
      --password <pw>     password for protected PDFs
      --keep-larger       keep results even when they are larger than the original
  -v, --verbose           show what was changed in each file
  -h, --help              show this help
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("smolpdf: \(message)\n".utf8))
    exit(64)
}

var profile = CompressionProfile.medium
var location = OutputLocation.default
var suffix: String?
var password: String?
var keepLarger = false
var verbose = false
var inputs: [URL] = []

var args = CommandLine.arguments.dropFirst()
func value(for flag: String) -> String {
    guard let v = args.popFirst() else { fail("\(flag) needs a value") }
    return v
}

var overrides: [(inout CompressionProfile) -> Void] = []
while let arg = args.popFirst() {
    switch arg {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "-p", "--profile":
        let name = value(for: arg).lowercased()
        guard let match = CompressionProfile.builtIns.first(where: { $0.name.lowercased() == name }) else {
            fail("unknown profile '\(name)'")
        }
        profile = match
    case "-q", "--quality":
        guard let q = Double(value(for: arg)), (0...100).contains(q) else { fail("quality must be 0-100") }
        overrides.append { $0.compressImages = true; $0.imageQuality = q / 100 }
    case "-r", "--resolution":
        guard let r = Int(value(for: arg)), r > 0 else { fail("resolution must be a positive number") }
        overrides.append { $0.compressImages = true; $0.maxResolution = r }
    case "-g", "--grayscale":
        overrides.append { $0.grayscale = true }
    case "-b", "--mono-scans":
        overrides.append { $0.monochromeScans = true }
    case "-m", "--strip-metadata":
        overrides.append { $0.removeMetadata = true }
    case "-x", "--strip":
        for item in value(for: arg).lowercased().split(separator: ",") {
            switch item.trimmingCharacters(in: .whitespaces) {
            case "metadata": overrides.append { $0.removeMetadata = true }
            case "editing": overrides.append { $0.removeEditingData = true }
            case "annotations": overrides.append { $0.removeAnnotations = true }
            case "bookmarks": overrides.append { $0.removeBookmarks = true }
            case "attachments": overrides.append { $0.removeAttachments = true }
            case "javascript": overrides.append { $0.removeJavaScript = true }
            case "all":
                overrides.append {
                    $0.removeMetadata = true
                    $0.removeEditingData = true
                    $0.removeAnnotations = true
                    $0.removeBookmarks = true
                    $0.removeAttachments = true
                    $0.removeJavaScript = true
                }
            default: fail("unknown --strip item '\(item)'")
            }
        }
    case "-o", "--output":
        let folder = URL(fileURLWithPath: value(for: arg), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        location = .folder(folder)
    case "-s", "--suffix":
        suffix = value(for: arg)
    case "--replace":
        location = .replaceOriginal
    case "--password":
        password = value(for: arg)
    case "--keep-larger":
        keepLarger = true
    case "-v", "--verbose":
        verbose = true
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
        inputs.append(URL(fileURLWithPath: arg))
    }
}
for apply in overrides { apply(&profile) }
if let suffix, case .sameFolder = location { location = .sameFolder(suffix: suffix) }

let files = PDFFinder.pdfs(in: inputs)
if files.isEmpty { fail("no PDF files given\n\n\(usage)") }

let formatter = ByteCountFormatter()
var totalBefore: Int64 = 0
var totalAfter: Int64 = 0
var failures = 0

print("Profile: \(profile.name) (\(profile.summary))")
for file in files {
    do {
        let result = try PDFCompressor.compress(
            input: file, output: location.destination(for: file), profile: profile,
            password: password, keepOriginalIfLarger: !keepLarger
        )
        totalBefore += result.originalSize
        totalAfter += result.compressedSize
        let before = formatter.string(fromByteCount: result.originalSize)
        if result.keptOriginal {
            print("= \(file.lastPathComponent): \(before), already optimal, original kept")
        } else {
            let after = formatter.string(fromByteCount: result.compressedSize)
            let pct = Int((result.savedFraction * 100).rounded())
            print("✓ \(file.lastPathComponent): \(before) → \(after) (−\(pct)%) → \(result.outputURL.path)")
        }
        if verbose, let d = result.details {
            var parts = ["\(d.imagesChanged) of \(d.images) images re-encoded"]
            if d.imagesChanged > 0 {
                parts[0] += " (\(formatter.string(fromByteCount: d.imageBytesBefore)) → \(formatter.string(fromByteCount: d.imageBytesAfter)))"
            }
            if d.imagesDownsampled > 0 { parts.append("\(d.imagesDownsampled) downsampled") }
            if d.streamsRecompressed > 0 { parts.append("\(d.streamsRecompressed) streams recompressed") }
            if d.duplicatesRemoved > 0 { parts.append("\(d.duplicatesRemoved) duplicates merged") }
            print("  " + parts.joined(separator: ", "))
        }
    } catch {
        failures += 1
        print("✗ \(file.lastPathComponent): \(error.localizedDescription)")
    }
}

if files.count > 1, totalBefore > 0 {
    let pct = Int((Double(totalBefore - totalAfter) / Double(totalBefore) * 100).rounded())
    print("Total: \(formatter.string(fromByteCount: totalBefore)) → \(formatter.string(fromByteCount: totalAfter)) (−\(pct)%)")
}
exit(failures == 0 ? 0 : 1)
