// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Visyn",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "VisynCapture", targets: ["VisynCapture"]),
        .library(name: "VisynBroadcast", targets: ["VisynBroadcast"])
    ],
    targets: [
        .target(
            name: "MMWormhole",
            path: "Vendor/MMWormhole",
            exclude: ["LICENSE", "README.md"],
            publicHeadersPath: "include",
            cSettings: [.define("MMWORMHOLE_FILE_ONLY")]
        ),
        .target(name: "VisynTransport", dependencies: ["MMWormhole"]),
        .target(
            name: "VisynCapture", dependencies: ["VisynTransport"],
            resources: [.copy("Resources/video.mov")]
        ),
        .target(name: "VisynBroadcast", dependencies: ["VisynTransport"]),
        .testTarget(name: "VisynTransportTests", dependencies: ["VisynTransport", "MMWormhole"]),
        .testTarget(name: "VisynCaptureTests", dependencies: ["VisynCapture"])
    ]
)
