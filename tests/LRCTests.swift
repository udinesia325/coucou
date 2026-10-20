import Foundation

@main
enum LRCTests {
    static func main() {
        let lines = LRC.parse("""
        [ar:Someone]
        [00:12.50] Hello there
        [00:05.00]Intro
        [01:00.00][02:00.00] Chorus
        [00:20.00]
        no tag here
        """)
        precondition(lines.map(\.text) == ["Intro", "Hello there", "", "Chorus", "Chorus"])
        precondition(lines.map(\.time) == [5, 12.5, 20, 60, 120])

        precondition(LRC.index(in: lines, at: 0) == nil)
        precondition(LRC.index(in: lines, at: 5) == 0)
        precondition(LRC.index(in: lines, at: 12.49) == 0)
        precondition(LRC.index(in: lines, at: 12.5) == 1)
        precondition(LRC.index(in: lines, at: 90) == 3)
        precondition(LRC.index(in: lines, at: 999) == 4)
        precondition(LRC.index(in: [], at: 3) == nil)
        precondition(LRC.parse("").isEmpty)

        // Karaoke: plain line fills at 0.13 s/char ("Hello there" = 11 chars, 1.43 s), capped by the next line.
        let i = LRC.index(in: lines, at: 12.5)!
        precondition(LRC.sung(in: lines, index: i, at: 12.5) == 0)
        precondition(abs(LRC.sung(in: lines, index: i, at: 12.5 + 0.715) - 5.5) < 0.001)
        precondition(LRC.sung(in: lines, index: i, at: 19) == 11)
        precondition(LRC.sung(in: lines, index: 0, at: 6) > 0 && LRC.sung(in: lines, index: 0, at: 12.4) == 5)
        precondition(LRC.sung(in: lines, index: 2, at: 25) == 0)   // empty line

        // Enhanced LRC: word tags drive it, and are stripped from the text.
        let w = LRC.parse("[00:10.00]<00:10.00>Hey <00:11.00>you<00:12.00>")
        precondition(w.map(\.text) == ["Hey you"])
        precondition(w[0].marks.map(\.offset) == [0, 3, 7])
        precondition(abs(LRC.sung(in: w, index: 0, at: 10.5) - 1.5) < 0.001)
        precondition(abs(LRC.sung(in: w, index: 0, at: 11.5) - 5) < 0.001)
        precondition(LRC.sung(in: w, index: 0, at: 13) == 7)
        precondition(LRC.parse("[00:01.00]a <b> c")[0].text == "a <b> c")

        print("LRC: 21 cases passed")
    }
}
