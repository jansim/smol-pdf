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
  -m, --strip-metadata    remove document metadata
  -o, --output <folder>   write results into this folder
  -s, --suffix <text>     file name suffix when writing next to the original (default: -compressed)
      --replace           replace the originals (they are moved to the Trash)
      --password <pw>     password for protected PDFs
      --keep-larger       keep results even when they are larger than the original
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
    case "-m", "--strip-metadata":
        overrides.append { $0.removeMetadata = true }
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
