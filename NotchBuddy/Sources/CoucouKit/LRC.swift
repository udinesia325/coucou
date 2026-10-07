import Foundation

/// One timed lyric line.
struct LyricLine: Equatable, Sendable {
    let time: Double   // seconds from track start
    let text: String
}

/// Synced lyrics in the LRC format ("[01:02.50] line"), as served by lrclib.net.
enum LRC {
    /// Parses timed lines; a line may carry several time tags. Metadata tags ([ar:…]) are skipped.
    static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let parts = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
                    times.append(m * 60 + s)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { LyricLine(time: $0, text: text) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// Index of the line being sung at `position`, nil before the first line.
    static func index(in lines: [LyricLine], at position: Double) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}
