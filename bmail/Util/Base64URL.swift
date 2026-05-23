import Foundation

enum Base64URL {
    static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
        t = t.replacingOccurrences(of: "_", with: "/")
        let pad = (4 - t.count % 4) % 4
        if pad > 0 { t.append(String(repeating: "=", count: pad)) }
        return Data(base64Encoded: t)
    }
}

extension Data {
    var b64u: String { Base64URL.encode(self) }
    init?(b64u: String) {
        guard let d = Base64URL.decode(b64u) else { return nil }
        self = d
    }
}
