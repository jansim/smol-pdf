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

    func testGrayscaleConvertsTextAndGraphics() throws {
        let input = dir.appendingPathComponent("vector.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = try XCTUnwrap(CGContext(input as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 600, width: 200, height: 150))
        ctx.setStrokeColor(CGColor(genericCMYKCyan: 1, magenta: 0, yellow: 1, black: 0, alpha: 1))
        ctx.setLineWidth(12)
        ctx.stroke(CGRect(x: 300, y: 600, width: 200, height: 150))
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)] as CFArray,
            locations: [0, 1]
        ))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 40, y: 350, width: 500, height: 200))
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 40, y: 0), end: CGPoint(x: 540, y: 0), options: [])
        ctx.restoreGState()
        let text = NSAttributedString(string: "Colored text", attributes: [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 48, nil),
            .foregroundColor: CGColor(srgbRed: 0.1, green: 0.6, blue: 0.2, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 40, y: 200)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        var profile = CompressionProfile.lossless.duplicate()
        profile.grayscale = true
        let output = dir.appendingPathComponent("gray.pdf")
        _ = try PDFCompressor.compress(input: input, output: output, profile: profile, keepOriginalIfLarger: false)

        let pixels = try render(output)
        var colored = 0, dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
            if rgb.max()! - rgb.min()! > 6 { colored += 1 }
            if rgb.max()! < 200 { dark += 1 }
        }
        XCTAssertEqual(colored, 0, "every color must be gray")
        XCTAssertGreaterThan(dark, pixels.count / 4 / 20, "the drawing must still be there")
        XCTAssertTrue(PDFDocument(url: output)?.string?.contains("Colored text") ?? false)
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
        // PDFKit saves the note with its popup, so count what's in the file.
        let annotations = try XCTUnwrap(PDFDocument(url: input)?.page(at: 0)?.annotations.count)
        XCTAssertGreaterThan(annotations, 0)

        let kept = dir.appendingPathComponent("kept.pdf")
        _ = try PDFCompressor.compress(input: input, output: kept, profile: .medium)
        let keptDoc = try XCTUnwrap(PDFDocument(url: kept))
        XCTAssertEqual(keptDoc.outlineRoot?.numberOfChildren, 1)
        XCTAssertEqual(keptDoc.page(at: 0)?.annotations.count, annotations)

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
        XCTAssertEqual(PDFFinder.pdfs(in: [dir]).map(\.lastPathComponent), ["a.pdf", "b.pdf"])
        XCTAssertEqual(PDFFinder.pdfs(in: [dir, dir.appendingPathComponent("a.pdf")]).count, 2, "each file once")
    }

    func testReportsProgress() throws {
        let input = try makePDF(named: "photo.pdf")
        var fractions: [Double] = []
        _ = try PDFCompressor.compress(input: input, output: dir.appendingPathComponent("out.pdf"), profile: .medium) {
            fractions.append($0)
        }
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions, fractions.sorted(), "progress never goes back")
        XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(fractions.last, 1)
    }

    func testCancellingStopsCompression() async throws {
        let input = try makePDF(named: "photo.pdf")
        let output = dir.appendingPathComponent("out.pdf")
        // The task cancels itself as soon as compression has started.
        let task = Task.detached {
            try PDFCompressor.compress(input: input, output: output, profile: .medium) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("compression should have been cancelled")
        } catch {
            XCTAssertEqual(error as? CompressionError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testTimeEstimate() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var short = TimeEstimate(start: start)
        short.update(fraction: 0.3, at: start + 1)
        short.update(fraction: 0.9, at: start + 3)
        XCTAssertNil(short.remaining, "runs projected to take less than 10 seconds show no estimate")

        var long = TimeEstimate(start: start)
        long.update(fraction: 0.1, at: start + 0.5)
        XCTAssertNil(long.remaining, "too early to tell")
        long.update(fraction: 0.1, at: start + 2)
        XCTAssertEqual(long.remaining ?? 0, 18, accuracy: 0.01)
        long.update(fraction: 0.3, at: start + 2.1)
        XCTAssertGreaterThan(long.remaining ?? 0, 15, "a jump in progress moves the estimate gradually")
        long.update(fraction: 0.9, at: start + 18)
        XCTAssertEqual(long.remaining ?? 0, 2, accuracy: 0.5)
        long.update(fraction: 0.95, at: start + 18.5)
        XCTAssertNotNil(long.remaining, "once shown, the estimate stays")
        long.update(fraction: 1, at: start + 19)
        XCTAssertEqual(long.remaining, 0)
    }

    func testLosslessKeepsColorKeyTransparency() throws {
        // Black and white squares in 8-bit gray, the white ones transparent through a color key. With fewer
        // bits per sample, the key's value 255 would no longer match them.
        let pixels = Data((0..<(400 * 400)).map { i -> UInt8 in ((i % 400) / 40 + i / 400 / 40) % 2 == 0 ? 255 : 0 })
        let input = try makeImagePDF(
            named: "key.pdf", image: "/Width 400 /Height 400 /ColorSpace /DeviceGray /BitsPerComponent 8 /Mask [255 255]",
            data: pixels
        )
        let output = dir.appendingPathComponent("out.pdf")
        _ = try PDFCompressor.compress(input: input, output: output, profile: .lossless, keepOriginalIfLarger: false)
        try assertSameRendering(input, output)
    }

    func testUnwrapsJPEGsInOtherFilters() throws {
        // Some generators wrap JPEGs in text encodings (ReportLab writes [/ASCII85Decode /DCTDecode]).
        let image = try makeImage(width: 800, height: 600)
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        let digits = Array("0123456789abcdef".utf8)
        var hex = Data(capacity: jpeg.count * 2 + 1)
        for byte in jpeg { hex.append(contentsOf: [digits[Int(byte >> 4)], digits[Int(byte & 15)]]) }
        hex.append(UInt8(ascii: ">"))
        let input = try makeImagePDF(
            named: "hex.pdf",
            image: "/Width 800 /Height 600 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter [/ASCIIHexDecode /DCTDecode]",
            data: hex
        )
        let output = dir.appendingPathComponent("out.pdf")
        let result = try PDFCompressor.compress(input: input, output: output, profile: .lossless)
        XCTAssertLessThan(result.compressedSize, result.originalSize * 6 / 10, "the JPEG is stored without its hex encoding")
        try assertSameRendering(input, output)
    }

    func testKeepsXMPMetadataUncompressed() throws {
        // Other tools (and PDF/A) expect the document's XMP metadata as plain text.
        let xmp = Data(("<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"></x:xmpmeta>"
            + String(repeating: " ", count: 2000) + "<?xpacket end=\"w\"?>").utf8)
        let input = try makeImagePDF(
            named: "xmp.pdf", image: "/Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", data: Data([0]),
            catalog: "/Metadata 6 0 R", extraObjects: [stream("/Type /Metadata /Subtype /XML", xmp)]
        )
        let output = dir.appendingPathComponent("out.pdf")
        _ = try PDFCompressor.compress(input: input, output: output, profile: .medium, keepOriginalIfLarger: false)
        XCTAssertNotNil(try Data(contentsOf: output).range(of: Data("<x:xmpmeta".utf8)))
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

    /// A one-page PDF, written by hand, that draws an image XObject (its dictionary entries and data) over red.
    /// Objects 1-5 are the catalog, pages, page, content and image; `extraObjects` are numbered from 6.
    func makeImagePDF(
        named name: String, image: String, data: Data, catalog: String = "", extraObjects: [Data] = []
    ) throws -> URL {
        let objects = [
            Data("<< /Type /Catalog /Pages 2 0 R \(catalog) >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>".utf8),
            stream("", Data("1 0 0 rg 0 0 400 400 re f q 400 0 0 300 0 50 cm /Im0 Do Q".utf8)),
            stream("/Type /XObject /Subtype /Image \(image)", data),
        ] + extraObjects
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        var trailer = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { trailer += String(format: "%010ld 00000 n \n", offset) }
        trailer += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(trailer.utf8))
        let url = dir.appendingPathComponent(name)
        try pdf.write(to: url)
        return url
    }

    /// A PDF stream object with these dictionary entries.
    func stream(_ dictionary: String, _ data: Data) -> Data {
        var stream = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
        stream.append(data)
        stream.append(Data("\nendstream".utf8))
        return stream
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
