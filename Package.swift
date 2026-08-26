// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "stupid-torrent-client",
    platforms: [
        .iOS("26.0"),
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
        .target(
            name: "StupidClientCore",
            dependencies: ["TorrentCore", "Streaming"]
        ),
        .target(
            name: "stupid_torrent_client",
            dependencies: [
                "StupidClientCore",
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
        .testTarget(
            name: "StupidTorrentClientAppTests",
            dependencies: ["StupidClientCore", "TorrentCore", "Bencode", "TorrentTestingSupport"]
        ),
    ]
)
