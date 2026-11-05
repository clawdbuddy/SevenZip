// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SevenZip",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SevenZip", targets: ["SevenZip"]),
        .executable(name: "SevenZipCLI", targets: ["SevenZipCLI"])
    ],
    targets: [
        .target(name: "ArchiveCore", path: "Sources/ArchiveCore"),
        .executableTarget(name: "SevenZip", dependencies: ["ArchiveCore"], path: "Sources/SevenZip"),
        .executableTarget(name: "SevenZipCLI", dependencies: ["ArchiveCore"], path: "Sources/SevenZipCLI"),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"], path: "Tests/ArchiveCoreTests")
    ]
)
