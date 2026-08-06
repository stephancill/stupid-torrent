import Foundation

public enum Fixtures {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static func url(named name: String) -> URL {
        packageRoot.appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    public static func data(named name: String) throws -> Data {
        try Data(contentsOf: url(named: name))
    }

    public static var bigBuckBunnyTorrentData: Data {
        get throws { try data(named: "big-buck-bunny.torrent") }
    }
}
