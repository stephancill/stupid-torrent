// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "stupid-torrent-client",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "stupid_torrent_client",
            targets: ["stupid_torrent_client"]
        ),
        // Headless macOS dev/test harness. xtool ignores executable products.
        .executable(
            name: "torrent-cli",
            targets: ["torrent-cli"]
        ),
    ],
    targets: [
        .target(
            name: "Bencode"
        ),
        .target(
            name: "TorrentCore",
            dependencies: ["Bencode"]
        ),
        .target(
            name: "Streaming",
            dependencies: ["TorrentCore"]
        ),
        // MobileVLCKit binary (iOS only; see docs/mkv-streaming.md "Packaging").
        // Populate Vendor/MobileVLCKit.xcframework before building (gitignored).
        .binaryTarget(
            name: "MobileVLCKit",
            path: "Vendor/MobileVLCKit.xcframework"
        ),
        .target(
            name: "VLCBridge",
            dependencies: [
                .target(name: "MobileVLCKit", condition: .when(platforms: [.iOS])),
                .target(name: "Streaming"),
                .target(name: "TorrentCore"),
            ],
            linkerSettings: [
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("OpenGLES"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedLibrary("c++"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
            ]
        ),
        .target(
            name: "stupid_torrent_client",
            dependencies: [
                "TorrentCore",
                "Streaming",
                .target(name: "VLCBridge", condition: .when(platforms: [.iOS])),
            ]
        ),
        .executableTarget(
            name: "torrent-cli",
            dependencies: ["TorrentCore", "Streaming"]
        ),
        .target(
            name: "TorrentTestingSupport",
            dependencies: ["TorrentCore"],
            path: "Tests/TorrentTestingSupport"
        ),
        .testTarget(
            name: "BencodeTests",
            dependencies: ["Bencode", "TorrentTestingSupport"]
        ),
        .testTarget(
            name: "TorrentCoreTests",
            dependencies: ["TorrentCore", "Bencode", "TorrentTestingSupport"]
        ),
        .testTarget(
            name: "StreamingTests",
            dependencies: ["Streaming", "TorrentCore", "TorrentTestingSupport"]
        ),
    ]
)
