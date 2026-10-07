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

        print("LRC: 10 cases passed")
    }
}
