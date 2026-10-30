import Foundation

/// Deterministic pixel avatars served at `/api/avatars/pixel/<key>.svg`.
/// The key is the part after `pixel:` from the stored avatar string.
public enum PixelAvatars {
    public static func decode(_ encoded: String) -> String? {
        guard encoded.wholeMatch(of: /^[A-Za-z0-9_-]{1,512}$/) != nil,
              let data = base64URLDecode(encoded),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty,
              key.utf8.count <= 256,
              !key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else {
            return nil
        }
        return key
    }

    public static func render(key: String) -> String? {
        if key.hasPrefix("random:") {
            return render(grid: generatedGrid(seed: String(key.dropFirst("random:".count))), background: "#111827")
        }
        if key == "cat" {
            return render(grid: catGrid, background: "#fbbf24")
        }
        return nil
    }

    private static func render(grid: [String], background: String) -> String {
        let palette: [Character: String] = [
            "K": "#111827",
            "W": "#f9fafb",
            "Y": "#fbbf24",
            "C": "#22d3ee",
            "V": "#a78bfa",
        ]
        var rects = ""
        for (y, row) in grid.enumerated() {
            for (x, symbol) in row.enumerated() where symbol != "_" {
                guard let fill = palette[symbol] else { continue }
                rects += "<rect x=\"\(x)\" y=\"\(y)\" width=\"1\" height=\"1\" fill=\"\(fill)\"/>"
            }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 8 8\" shape-rendering=\"crispEdges\"><rect width=\"8\" height=\"8\" fill=\"\(background)\"/>\(rects)</svg>"
    }

    /// A mirrored 8x8 monochrome grid seeded by the key.
    private static func generatedGrid(seed: String) -> [String] {
        var state = fnv1a(seed)
        var rows: [String] = []
        for _ in 0..<8 {
            var left: [Character] = []
            for _ in 0..<4 {
                state = splitMix64(state)
                left.append((state >> 33) % 100 < 45 ? "K" : "_")
            }
            let right = left.reversed()
            rows.append(String(left + right))
        }
        return rows
    }

    private static func fnv1a(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private static func splitMix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    private static let catGrid: [String] = [
        "K______K",
        "KK____KK",
        "KYKYYKYK",
        "KYYYYYYK",
        "KYKYYKYK",
        "_KYYYYK_",
        "__KYYK__",
        "___KK___",
    ]
}
