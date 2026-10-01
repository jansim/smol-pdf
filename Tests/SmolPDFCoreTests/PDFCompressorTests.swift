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

    func testLosslessKeepsEveryPixel() throws {
        // A screenshot-like image with few colors: stored as a palette, pixels unchanged.
        let input = try makePDF(named: "screen.pdf", image: makeImage(width: 1200, height: 900, flat: true))
        let output = dir.appendingPathComponent("out.pdf")
        let result = try PDFCompressor.compress(input: input, output: output, profile: .lossless)

        XCTAssertFalse(result.keptOriginal)
        XCTAssertLessThan(result.compressedSize, result.originalSize)
        XCTAssertEqual(result.details?.imagesDownsampled, 0)
        try assertSameRendering(input, output)
    }

    func testEngineReportsWhatChanged() throws {
        let input = try makePDF(named: "photo.pdf")
        let result = try PDFCompressor.compress(input: input, output: dir.appendingPathComponent("out.pdf"), profile: .medium)
        let details = try XCTUnwrap(result.details)
        XCTAssertGreaterThanOrEqual(details.images, 1)
        XCTAssertGreaterThanOrEqual(details.imagesChanged, 1)
        XCTAssertGreaterThanOrEqual(details.imagesDownsampled, 1, "a 224 dpi photo goes down to 150 dpi")
        XCTAssertLessThan(details.imageBytesAfter, details.imageBytesBefore)
    }

    func testBlackAndWhiteScansBecomeOneBit() throws {
        // A full-page 300 dpi scan of "text", stored as 8-bit gray.
        let scan = try makeScan(width: 2480, height: 3508)
        let input = try makePDF(named: "scan.pdf", image: scan, imageRect: CGRect(x: 0, y: 0, width: 595, height: 842), text: false)
        let output = dir.appendingPathComponent("out.pdf")
        let result = try PDFCompressor.compress(input: input, output: output, profile: .lossless)
        XCTAssertLessThan(result.compressedSize, result.originalSize / 4)
        try assertSameRendering(input, output)
    }

    func testRemovesDocumentParts() throws {
        let input = try makePDF(named: "parts.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: input))
        let outline = PDFOutline()
        let item = PDFOutline()
        item.label = "Chapter"
        item.destination = PDFDestination(page: doc.page(at: 0)!, at: .zero)
        outline.insertChild(item, at: 0)
        doc.outlineRoot = outline
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
        doc.page(at: 0)!.addAnnotation(note)
        XCTAssertTrue(doc.write(to: input))

        let kept = dir.appendingPathComponent("kept.pdf")
        _ = try PDFCompressor.compress(input: input, output: kept, profile: .medium)
        let keptDoc = try XCTUnwrap(PDFDocument(url: kept))
        XCTAssertEqual(keptDoc.outlineRoot?.numberOfChildren, 1)
        XCTAssertEqual(keptDoc.page(at: 0)?.annotations.count, 1)

        var profile = CompressionProfile.medium.duplicate()
        profile.removeBookmarks = true
        profile.removeAnnotations = true
        let removed = dir.appendingPathComponent("removed.pdf")
        _ = try PDFCompressor.compress(input: input, output: removed, profile: profile)
        let removedDoc = try XCTUnwrap(PDFDocument(url: removed))
        XCTAssertEqual(removedDoc.outlineRoot?.numberOfChildren ?? 0, 0)
        XCTAssertEqual(removedDoc.page(at: 0)?.annotations.count, 0)
        XCTAssertTrue(removedDoc.string?.contains("Hello smol-pdf") ?? false)
    }

    func testDecodesProfilesSavedBeforeNewSettings() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000003","name":"Medium","isBuiltIn":true,"compressImages":true,
         "imageQuality":0.5,"maxResolution":200,"grayscale":false,"removeMetadata":true,
         "removeAnnotations":false,"removeBookmarks":false}
        """
        let profile = try JSONDecoder().decode(CompressionProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.imageQuality, 0.5)
        XCTAssertEqual(profile.maxResolution, 200)
        XCTAssertTrue(profile.removeMetadata)
        XCTAssertFalse(profile.monochromeScans)
        XCTAssertFalse(profile.removeAttachments)
        let roundTrip = try JSONDecoder().decode(CompressionProfile.self, from: JSONEncoder().encode(CompressionProfile.maximum))
        XCTAssertEqual(roundTrip, .maximum)
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

    /// A two-page PDF with a large noisy photo-like image (unless another is given) and a line of real text.
    func makePDF(
        named name: String, title: String? = nil, image: CGImage? = nil,
        imageRect: CGRect = CGRect(x: 40, y: 300, width: 515, height: 386), text: Bool = true
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        let image = try image ?? makeImage(width: 1600, height: 1200)
        for _ in 0..<2 {
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: imageRect)
            guard text else {
                ctx.endPDFPage()
                continue
            }
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

    /// A noisy photo-like image, or with `flat`, a screenshot-like one with a few solid colors.
    func makeImage(width: Int, height: Int, flat: Bool = false) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var rng = SystemRandomNumberGenerator()
        let palette: [(UInt8, UInt8, UInt8)] = [(245, 245, 250), (30, 30, 30), (200, 40, 40), (40, 120, 200)]
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if flat {
                    let c = palette[((y / 40) + (x / 300)) % palette.count]
                    (pixels[i], pixels[i + 1], pixels[i + 2]) = c
                    continue
                }
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

    /// A black-and-white "text" scan in 8-bit gray.
    func makeScan(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height)
        var rng = SystemRandomNumberGenerator()
        for line in stride(from: 150, to: height - 150, by: 60) {
            var x = 150
            while x < width - 300 {
                let word = Int.random(in: 40...220, using: &rng)
                for y in line..<(line + 30) {
                    for xx in x..<(x + word) { pixels[y * width + xx] = 0 }
                }
                x += word + Int.random(in: 20...50, using: &rng)
            }
        }
        let ctx = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Both files' first pages look the same (allowing for rounding in the renderer).
    func assertSameRendering(_ a: URL, _ b: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let pa = try render(a), pb = try render(b)
        XCTAssertEqual(pa.count, pb.count, file: file, line: line)
        let different = zip(pa, pb).filter { abs(Int($0) - Int($1)) > 2 }.count
        XCTAssertLessThan(different, pa.count / 1000, "\(different) of \(pa.count) samples differ", file: file, line: line)
    }

    /// The first page rendered to RGBA pixels.
    func render(_ url: URL) throws -> [UInt8] {
        let page = try XCTUnwrap(CGPDFDocument(url as CFURL)?.page(at: 1))
        let width = 300, height = 424
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: CGFloat(width) / 595, y: CGFloat(height) / 842)
        ctx.drawPDFPage(page)
        return pixels
    }
}
