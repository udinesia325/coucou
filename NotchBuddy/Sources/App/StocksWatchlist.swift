import Foundation

/// Reads the watchlist of Apple's Stocks app, in the order you arranged it, from the
/// CloudKit cache Stocks keeps in its group container. The symbols are Yahoo Finance
/// symbols (GC=F, ^JKSE, BBCA.JK…), so they can be priced with the same source.
enum StocksWatchlist {
    static let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Group Containers/group.com.apple.stocks/Library/Documents/PrivateData/com.apple.stocks.private-production-dbstore.json")

    /// nil when the file can't be read (no Stocks data, sandbox, or a format change).
    static func read(from url: URL = store) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zones = (json["database"] as? [String: Any])?["zones"] as? [[String: Any]],
              let zone = zones.first(where: { $0["name"] as? String == "Watchlist" }),
              let records = zone["serverRecords"] as? [String] else { return nil }
        // ponytail: first watchlist record that has symbols ("My Symbols"); other lists ignored.
        for record in records {
            guard let archive = Data(base64Encoded: record),
                  let plist = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
                  let objects = plist["$objects"] as? [Any] else { continue }
            for case let blob as Data in objects {
                if let symbols = stringArray(blob), !symbols.isEmpty { return symbols }
            }
        }
        return nil
    }

    /// The symbols field is a CKEncryptedStringArray whose bytes are protobuf: repeated
    /// field 13 strings (tag 0x6A, length, UTF-8). Anything else returns nil.
    static func stringArray(_ data: Data) -> [String]? {
        let bytes = [UInt8](data)
        var i = 0, out: [String] = []
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < bytes.count, shift < 35 {
                let b = bytes[i]; i += 1
                value |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint(), key == 0x6A, let len = varint(), len > 0, i + len <= bytes.count,
                  let s = String(bytes: bytes[i..<i + len], encoding: .utf8) else { return nil }
            out.append(s)
            i += len
        }
        return out.isEmpty ? nil : out
    }
}
