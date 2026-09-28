import AppKit
import CoreText
import PDFKit
import XCTest
@testable import SmolPDFCore

final class PDFCompressorTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        // Keep fixtures inside the (git-ignored) build folder of the repo.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        dir = root.appendingPathComponent(".build/test-fixtures/\(name.filter(\.isLetter))", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCompressesImagesAndKeepsText() throws {
        let input = try makePDF(named: "photo.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        let result = try PDFCompressor.compress(input: input, output: output, profile: .medium)

        XCTAssertFalse(result.keptOriginal)
        XCTAssertLessThan(result.compressedSize, result.originalSize / 2)
        let doc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertTrue(doc.string?.contains("Hello smol-pdf") ?? false, "text must stay text")
    }

    func testStrongerProfilesProduceSmallerFiles() throws {
        let input = try makePDF(named: "photo.pdf")
        let low = try PDFCompressor.compress(input: input, output: dir.appendingPathComponent("low.pdf"), profile: .low)
        let max = try PDFCompressor.compress(input: input, output: dir.appendingPathComponent("max.pdf"), profile: .maximum)
        XCTAssertLessThan(max.compressedSize, low.compressedSize)
    }

    func testGrayscaleAndMetadataRemoval() throws {
        let input = try makePDF(named: "photo.pdf", title: "Secret Title")
        var profile = CompressionProfile.medium.duplicate()
        profile.grayscale = true
        profile.removeMetadata = true
        let output = dir.appendingPathComponent("gray.pdf")
        _ = try PDFCompressor.compress(input: input, output: output, profile: profile)

        let doc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertNil(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute])
        XCTAssertTrue(doc.string?.contains("Hello smol-pdf") ?? false)

        // Sample the middle of the photo: it must have no color left.
        let thumb = try XCTUnwrap(doc.page(at: 0)?.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(thumb.tiffRepresentation)))
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.03)
        XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.03)
    }

    func testPasswordProtectedInput() throws {
        let plain = try makePDF(named: "plain.pdf")
        let locked = dir.appendingPathComponent("locked.pdf")
        XCTAssertTrue(PDFDocument(url: plain)!.write(to: locked, withOptions: [
            .userPasswordOption: "pw", .ownerPasswordOption: "pw",
        ]))
        let output = dir.appendingPathComponent("out.pdf")

        XCTAssertThrowsError(try PDFCompressor.compress(input: locked, output: output, profile: .medium)) {
            XCTAssertEqual($0 as? CompressionError, .passwordRequired)
        }
        XCTAssertThrowsError(try PDFCompressor.compress(input: locked, output: output, profile: .medium, password: "nope")) {
            XCTAssertEqual($0 as? CompressionError, .wrongPassword)
        }
        _ = try PDFCompressor.compress(input: locked, output: output, profile: .medium, password: "pw")
        let doc = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertTrue(doc.isLocked, "output keeps the password")
        XCTAssertTrue(doc.unlock(withPassword: "pw"))
    }

    func testKeepsOriginalWhenNotSmaller() throws {
        let input = try makePDF(named: "photo.pdf")
        let small = dir.appendingPathComponent("small.pdf")
        _ = try PDFCompressor.compress(input: input, output: small, profile: .maximum)
        // Compressing the already-compressed file at a higher quality can't make it smaller.
        let output = dir.appendingPathComponent("again.pdf")
        let result = try PDFCompressor.compress(input: small, output: output, profile: .low)
        XCTAssertTrue(result.keptOriginal)
        XCTAssertEqual(result.outputURL, small)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testOutputLocationNaming() throws {
        let input = try makePDF(named: "report.pdf")
        XCTAssertEqual(OutputLocation.default.destination(for: input).lastPathComponent, "report-compressed.pdf")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("report-compressed.pdf").path, contents: Data())
        XCTAssertEqual(OutputLocation.default.destination(for: input).lastPathComponent, "report-compressed 2.pdf")
        XCTAssertEqual(OutputLocation.replaceOriginal.destination(for: input), input)
        XCTAssertEqual(OutputLocation.folder(dir).destination(for: input).lastPathComponent, "report-compressed 2.pdf")
    }

    func testFinderExpandsFolders() throws {
        _ = try makePDF(named: "a.pdf")
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try makePDF(named: "sub/b.pdf")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data("x".utf8))
        XCTAssertEqual(Set(PDFFinder.pdfs(in: [dir]).map(\.lastPathComponent)), ["a.pdf", "b.pdf"])
    }

    // MARK: - Fixtures

    /// A two-page PDF with a large noisy photo-like image and a line of real text.
    func makePDF(named name: String, title: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        let image = try makeImage(width: 1600, height: 1200)
        for _ in 0..<2 {
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: CGRect(x: 40, y: 300, width: 515, height: 386))
            let text = NSAttributedString(string: "Hello smol-pdf", attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, 24, nil),
            ])
            ctx.textPosition = CGPoint(x: 40, y: 200)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func makeImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var rng = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x * 255) / width) &+ UInt8.random(in: 0...40, using: &rng)
                pixels[i + 1] = UInt8((y * 255) / height) &+ UInt8.random(in: 0...40, using: &rng)
                pixels[i + 2] = UInt8.random(in: 80...200, using: &rng)
            }
        }
        let ctx = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        return try XCTUnwrap(ctx.makeImage())
    }
}
