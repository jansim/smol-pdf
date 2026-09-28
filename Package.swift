// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "smol-pdf",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SmolPDFApp", targets: ["SmolPDFApp"]),
        .executable(name: "smolpdf", targets: ["smolpdf"]),
        .library(name: "SmolPDFCore", targets: ["SmolPDFCore"]),
    ],
    targets: [
        .target(name: "SmolPDFCore"),
        .executableTarget(name: "SmolPDFApp", dependencies: ["SmolPDFCore"]),
        .executableTarget(name: "smolpdf", dependencies: ["SmolPDFCore"]),
        .testTarget(name: "SmolPDFCoreTests", dependencies: ["SmolPDFCore"]),
    ],
    swiftLanguageModes: [.v5]
)
