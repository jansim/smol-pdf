// swift-tools-version: 6.0
import PackageDescription

// C/C++ libraries are git submodules in Vendor/<target>/<library>, pinned to release tags
// (clone with --recursive). Each Vendor/<target> folder adds the config headers their own build
// systems would generate. Their code is built with warnings off: it isn't ours to fix.
let quiet: [CSetting] = [.unsafeFlags(["-w"])]
let quietCXX: [CXXSetting] = [.unsafeFlags(["-w"])]

// mozjpeg 4.1.5: the library sources (JPEG_SOURCES in its CMakeLists.txt), arithmetic decoding,
// no SIMD. Files such as jccolext.c are #included by others and stay out of this list.
let mozjpeg = """
    jcapimin jcapistd jccoefct jccolor jcdctmgr jchuff jcext jcicc jcinit jcmainct jcmarker jcmaster
    jcomapi jcparam jcphuff jcprepct jcsample jctrans jdapimin jdapistd jdatadst jdatasrc jdcoefct
    jdcolor jddctmgr jdhuff jdicc jdinput jdmainct jdmarker jdmaster jdmerge jdphuff jdpostct jdsample
    jdtrans jerror jfdctflt jfdctfst jfdctint jidctflt jidctfst jidctint jidctred jquant1 jquant2 jutils
    jmemmgr jmemnobs jaricom jdarith jsimd_none
    """.split(whereSeparator: \.isWhitespace).map { "mozjpeg/\($0).c" }

// Header folders inside the submodules, for the targets that use them.
let qpdfHeaders = "../../Vendor/CQPDF/qpdf/include"
let jpegHeaders = "../../Vendor/CJPEG/mozjpeg"
let deflateHeaders = "../../Vendor/CDeflate/libdeflate"

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
            path: "Vendor/CJPEG",
            sources: mozjpeg,
            cSettings: quiet + [.headerSearchPath("config"), .headerSearchPath("mozjpeg")]
        ),
        // libdeflate: Flate compression that beats zlib.
        .target(
            name: "CDeflate",
            path: "Vendor/CDeflate",
            sources: ["adler32.c", "deflate_compress.c", "utils.c", "zlib_compress.c", "x86/cpu_features.c", "arm/cpu_features.c"]
                .map { "libdeflate/lib/\($0)" },
            cSettings: quiet + [.headerSearchPath("libdeflate")]
        ),
        // qpdf: the PDF object model, stream filters, encryption and writer.
        .target(
            name: "CQPDF",
            dependencies: ["CJPEG"],
            path: "Vendor/CQPDF",
            exclude: [
                // Other crypto providers, the command-line job layer, and a file #included by others.
                "QPDFCrypto_gnutls.cc", "QPDFCrypto_openssl.cc", "QPDFJob.cc", "QPDFJob_argv.cc",
                "QPDFJob_config.cc", "QPDFJob_json.cc", "qpdfjob-c.cc", "QPDFArgParser.cc", "sph/md_helper.c",
            ].map { "qpdf/libqpdf/\($0)" },
            sources: ["qpdf/libqpdf"],
            cSettings: quiet + [.headerSearchPath("config"), .headerSearchPath("qpdf/include"), .headerSearchPath("qpdf/libqpdf")],
            cxxSettings: quietCXX + [
                .headerSearchPath("config"), .headerSearchPath("qpdf/include"), .headerSearchPath("qpdf/libqpdf"),
                .headerSearchPath("../CJPEG/mozjpeg"), .define("QPDF_DISABLE_QTC", to: "1"),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        // The compression engine (C++ with a C interface).
        .target(
            name: "SmolPDFEngine",
            dependencies: ["CQPDF", "CJPEG", "CDeflate"],
            cSettings: [.headerSearchPath(jpegHeaders)],
            cxxSettings: [.headerSearchPath(qpdfHeaders), .headerSearchPath(jpegHeaders), .headerSearchPath(deflateHeaders)]
        ),

        .target(name: "SmolPDFCore", dependencies: ["SmolPDFEngine"]),
        .executableTarget(name: "SmolPDFApp", dependencies: ["SmolPDFCore"]),
        .executableTarget(name: "smolpdf", dependencies: ["SmolPDFCore"]),
        .testTarget(name: "SmolPDFCoreTests", dependencies: ["SmolPDFCore"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx20
)
