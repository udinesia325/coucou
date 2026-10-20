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

        // Karaoke, line-synced only: the whole line at once, from its start.
        let i = LRC.index(in: lines, at: 12.5)!
        precondition(LRC.sung(in: lines, index: i, at: 12.4) == 0)
        precondition(LRC.sung(in: lines, index: i, at: 12.5) == 11)
        precondition(LRC.sung(in: lines, index: 2, at: 25) == 0)   // empty line

        // Enhanced LRC: whole words from their own tags; tags stripped from the text.
        let w = LRC.parse("[00:10.00]<00:10.00>Hey <00:11.00>you<00:12.00>")
        precondition(w.map(\.text) == ["Hey you"])
        precondition(w[0].marks.map(\.offset) == [0, 3, 7])
        precondition(LRC.sung(in: w, index: 0, at: 9.9) == 0)
        precondition(LRC.sung(in: w, index: 0, at: 10) == 3)      // "Hey"
        precondition(LRC.sung(in: w, index: 0, at: 10.9) == 3)
        precondition(LRC.sung(in: w, index: 0, at: 11) == 7)      // "Hey you"
        precondition(LRC.sung(in: w, index: 0, at: 13) == 7)
        let late = LRC.parse("[00:10.00]Oh <00:11.00>yes")   // untagged start waits for the first tag
        precondition(LRC.sung(in: late, index: 0, at: 10.5) == 0 && LRC.sung(in: late, index: 0, at: 11) == 6)
        precondition(LRC.parse("[00:01.00]a <b> c")[0].text == "a <b> c")

        print("LRC: 22 cases passed")
    }
}
