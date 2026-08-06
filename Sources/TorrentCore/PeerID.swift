import Foundation

public enum PeerID {
    public static let prefix = "-ST0001-"

    public static func generate(prefix: String = PeerID.prefix) -> Data {
        var id = Data(prefix.utf8)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        while id.count < 20 {
            id.append(alphabet.randomElement()!.asciiValue!)
        }
        return id
    }
}
