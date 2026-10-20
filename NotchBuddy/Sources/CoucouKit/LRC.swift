import Foundation

/// One timed lyric line.
struct LyricLine: Equatable, Sendable {
    /// A word timing from enhanced LRC ("<00:12.34>word"): from `time`, `offset` characters are sung.
    struct Mark: Equatable, Sendable {
        let time: Double
        let offset: Int
    }

    let time: Double   // seconds from track start
    let text: String
    var marks: [Mark] = []
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
            let (text, marks) = words(rest.trimmingCharacters(in: .whitespaces))
            lines += times.map { LyricLine(time: $0, text: text, marks: marks) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// Strips enhanced-LRC word tags ("<00:12.34>"), keeping where each one falls in the text.
    private static func words(_ raw: String) -> (String, [LyricLine.Mark]) {
        var text = "", marks: [LyricLine.Mark] = []
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "<") {
            text += rest[..<open]
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            let parts = rest[rest.index(after: open)..<close].split(separator: ":")
            if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) {
                marks.append(.init(time: m * 60 + sec, offset: text.trimmingCharacters(in: .whitespaces).count))
            } else {
                text += rest[open...close]   // not a time tag: keep it as text
            }
            rest = rest[rest.index(after: close)...]
        }
        text += rest
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (trimmed, marks.map { .init(time: $0.time, offset: min($0.offset, trimmed.count)) })
    }

    /// How many characters of line `i` are sung at `position`, for karaoke. Enhanced LRC:
    /// whole words, each from its own word tag. Line-synced only: the whole line at once.
    static func sung(in lines: [LyricLine], index i: Int, at position: Double) -> Int {
        let line = lines[i], n = line.text.count
        guard position >= line.time else { return 0 }
        guard let k = line.marks.lastIndex(where: { $0.time <= position }) else {
            return line.marks.isEmpty ? n : 0
        }
        // The word starting at mark k runs to the next mark (or the end of the line).
        return line.marks.indices.contains(k + 1) ? line.marks[k + 1].offset : n
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
