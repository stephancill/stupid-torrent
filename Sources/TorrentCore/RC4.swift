import Foundation

final class RC4: @unchecked Sendable {
    private var s: [UInt8] = Array(0...255)
    private var i: UInt8 = 0
    private var j: UInt8 = 0

    init(key: Data) {
        let keyBytes = [UInt8](key)
        var ksaJ: UInt8 = 0
        for index in 0..<256 {
            ksaJ = ksaJ &+ s[index] &+ keyBytes[index % keyBytes.count]
            let tmp = s[index]
            s[index] = s[Int(ksaJ)]
            s[Int(ksaJ)] = tmp
        }
        i = 0
        j = 0
        let discard = Data(repeating: 0, count: 1024)
        _ = crypt(discard)
    }

    func update(_ data: Data) -> Data {
        crypt(data)
    }

    private func crypt(_ data: Data) -> Data {
        var out = [UInt8](repeating: 0, count: data.count)
        for (index, byte) in data.enumerated() {
            i = i &+ 1
            j = j &+ s[Int(i)]
            let tmp = s[Int(i)]
            s[Int(i)] = s[Int(j)]
            s[Int(j)] = tmp
            let k = s[Int(i)] &+ s[Int(j)]
            out[index] = byte ^ s[Int(k)]
        }
        return Data(out)
    }
}
