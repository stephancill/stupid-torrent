// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "stupid-torrent-client",
    platforms: [
        .iOS("26.0"),
        .tvOS("26.0"),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "stupid_torrent_client",
            targets: ["stupid_torrent_client"]
        ),
        .library(
            name: "StupidClientCore",
            targets: ["StupidClientCore"]
        ),
        .library(
            name: "StupidClientUI",
            targets: ["StupidClientUI"]
        ),
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
            name: "StupidClientUI",
            dependencies: ["StupidClientCore", "TorrentCore", "Streaming"]
        ),
        .target(
            name: "stupid_torrent_client",
            dependencies: [
                "StupidClientCore",
                "StupidClientUI",
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
            name: "StupidClientCoreTests",
            dependencies: ["StupidClientCore", "TorrentCore", "TorrentTestingSupport"]
        ),
    ]
)
