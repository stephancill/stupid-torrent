// swift-tools-version: 6.0

import PackageDescription

// The tvOS app: its own stupid-app project (see stupid-app.yml here) built on the shared engine
// and store from the parent package.
let package = Package(
    name: "StupidTorrentTV",
    platforms: [
        .tvOS("26.0"),
    ],
    products: [
        .library(
            name: "StupidTorrentTV",
            targets: ["StupidTorrentTV"]
        ),
    ],
    dependencies: [
        .package(name: "stupid-torrent-client", path: ".."),
    ],
    targets: [
        .target(
            name: "StupidTorrentTV",
            dependencies: [
                .product(name: "StupidClientCore", package: "stupid-torrent-client"),
                .product(name: "StupidClientUI", package: "stupid-torrent-client"),
            ]
        ),
    ]
)
