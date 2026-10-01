import CoreGraphics
import Foundation
import PDFKit
import XCTest
@testable import SmolPDFCore

/// Compares the engine with the previous Quartz-filter implementation on a folder of PDFs.
///
/// Skipped unless SMOL_COMPARE_DIR names a folder; see scripts/compare/compare.sh. For every file
/// and built-in profile it reports the size, time and how close each result looks to the original
/// (PSNR of page renderings, 99 = identical). Results go to stdout and `comparison.md` in the folder.
final class QuartzComparisonTests: XCTestCase {
    func testCompareWithQuartz() throws {
        guard let folder = ProcessInfo.processInfo.environment["SMOL_COMPARE_DIR"] else {
            throw XCTSkip("set SMOL_COMPARE_DIR to run the comparison")
        }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        let out = dir.appendingPathComponent("results", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no PDFs in \(folder)")

        var lines = [
            "| File | Profile | Original | Quartz | Engine | Quartz PSNR | Engine PSNR | Quartz time | Engine time |",
            "|---|---|--:|--:|--:|--:|--:|--:|--:|",
        ]
        var totals: [String: (original: Int64, quartz: Int64, engine: Int64)] = [:]
        for file in files {
            let password: String? = file.lastPathComponent.contains("encrypted") ? "pw" : nil
            let original = PDFCompressor.fileSize(file)
            let reference = try renderAll(file, password: password)
            for profile in CompressionProfile.builtIns {
                let stem = "\(file.deletingPathExtension().lastPathComponent)-\(profile.name)"

                // The previous implementation: structural changes in PDFKit, images through the Quartz filter.
                let quartzURL = out.appendingPathComponent("\(stem)-quartz.pdf")
                var start = Date()
                try PDFCompressor.quartzCompress(
                    input: file, output: quartzURL, filter: PDFCompressor.makeFilter(for: profile),
                    profile: profile, password: password
                )
                let quartzTime = Date().timeIntervalSince(start)

                let engineURL = out.appendingPathComponent("\(stem)-engine.pdf")
                start = Date()
                _ = try PDFCompressor.compress(
                    input: file, output: engineURL, profile: profile, password: password, keepOriginalIfLarger: false
                )
                let engineTime = Date().timeIntervalSince(start)

                let quartzSize = PDFCompressor.fileSize(quartzURL)
                let engineSize = PDFCompressor.fileSize(engineURL)
                let quartzPSNR = psnr(reference, try renderAll(quartzURL, password: password))
                let enginePSNR = psnr(reference, try renderAll(engineURL, password: password))
                lines.append(
                    "| \(file.lastPathComponent) | \(profile.name) | \(kb(original)) | \(kb(quartzSize)) | "
                        + "**\(kb(engineSize))** | \(db(quartzPSNR)) | \(db(enginePSNR)) | "
                        + String(format: "%.2fs | %.2fs |", quartzTime, engineTime)
                )
                var t = totals[profile.name] ?? (0, 0, 0)
                t.original += original
                t.quartz += quartzSize
                t.engine += engineSize
                totals[profile.name] = t
            }
        }
        lines.append("")
        lines.append("| Profile | Original | Quartz | Engine |")
        lines.append("|---|--:|--:|--:|")
        for profile in CompressionProfile.builtIns {
            guard let t = totals[profile.name] else { continue }
            lines.append("| \(profile.name) | \(kb(t.original)) | \(kb(t.quartz)) (\(pct(t.quartz, t.original))) | "
                + "\(kb(t.engine)) (\(pct(t.engine, t.original))) |")
        }
        let report = lines.joined(separator: "\n")
        print("\n" + report + "\n")
        try report.write(to: dir.appendingPathComponent("comparison.md"), atomically: true, encoding: .utf8)
    }

    private func kb(_ bytes: Int64) -> String {
        bytes < 10_000 ? String(format: "%.1f KB", Double(bytes) / 1000) : "\(Int((Double(bytes) / 1000).rounded())) KB"
    }

    private func pct(_ size: Int64, _ original: Int64) -> String {
        String(format: "−%.1f%%", 100 * (1 - Double(size) / Double(original)))
    }

    private func db(_ value: Double) -> String {
        value >= 99 ? "identical" : String(format: "%.1f dB", value)
    }

    /// All pages at 100 dpi, as RGBA.
    private func renderAll(_ url: URL, password: String?) throws -> [[UInt8]] {
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL), "can't open \(url.lastPathComponent)")
        if doc.isEncrypted, let password { _ = doc.unlockWithPassword(password) }
        return try (1...max(1, doc.numberOfPages)).map { index in
            let page = try XCTUnwrap(doc.page(at: index))
            let box = page.getBoxRect(.mediaBox)
            let scale = 100.0 / 72
            let width = Int(box.width * scale), height = Int(box.height * scale)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let ctx = try XCTUnwrap(CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            return pixels
        }
    }

    /// Peak signal-to-noise ratio over all pages (higher is closer; 99 means identical).
    private func psnr(_ a: [[UInt8]], _ b: [[UInt8]]) -> Double {
        guard a.count == b.count else { return 0 }
        var squared = 0.0, count = 0.0
        for (pa, pb) in zip(a, b) {
            guard pa.count == pb.count else { return 0 }
            for i in stride(from: 0, to: pa.count, by: 4) {
                for c in 0..<3 {
                    let d = Double(pa[i + c]) - Double(pb[i + c])
                    squared += d * d
                }
                count += 3
            }
        }
        let mse = squared / max(count, 1)
        return mse == 0 ? 99 : min(99, 10 * log10(255 * 255 / mse))
    }
}
