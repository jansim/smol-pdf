// swift-tools-version: 6.0
import PackageDescription

// Vendored C/C++ code (see scripts/vendor-deps.sh) is built with warnings off: it isn't ours to fix.
let vendored: [CSetting] = [.unsafeFlags(["-w"])]
let vendoredCXX: [CXXSetting] = [.unsafeFlags(["-w"])]

let package = Package(
    name: "smol-pdf",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SmolPDFApp", targets: ["SmolPDFApp"]),
        .executable(name: "smolpdf", targets: ["smolpdf"]),
        .library(name: "SmolPDFCore", targets: ["SmolPDFCore"]),
    ],
    targets: [
        // mozjpeg: JPEG decoding and (smaller) encoding.
        .target(
            name: "CJPEG",
            exclude: ["fragments", "LICENSE.md", "README.ijg"],
            cSettings: vendored + [.headerSearchPath("fragments")]
        ),
        // libdeflate: Flate compression that beats zlib.
        .target(
            name: "CDeflate",
            exclude: ["COPYING"],
            cSettings: vendored
        ),
        // qpdf: the PDF object model, stream filters, encryption and writer.
        .target(
            name: "CQPDF",
            dependencies: ["CJPEG"],
            exclude: ["LICENSE.txt", "NOTICE.md", "libqpdf/sph/md_helper.c"],
            sources: ["libqpdf"],
            cSettings: vendored + [.headerSearchPath("libqpdf")],
            cxxSettings: vendoredCXX + [.headerSearchPath("libqpdf"), .define("QPDF_DISABLE_QTC", to: "1")],
            linkerSettings: [.linkedLibrary("z")]
        ),
        // The compression engine (C++ with a C interface).
        .target(name: "SmolPDFEngine", dependencies: ["CQPDF", "CJPEG", "CDeflate"]),

        .target(name: "SmolPDFCore", dependencies: ["SmolPDFEngine"]),
        .executableTarget(name: "SmolPDFApp", dependencies: ["SmolPDFCore"]),
        .executableTarget(name: "smolpdf", dependencies: ["SmolPDFCore"]),
        .testTarget(name: "SmolPDFCoreTests", dependencies: ["SmolPDFCore"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx20
)
