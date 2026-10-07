import Foundation

@main
enum StocksWatchlistTests {
    static func main() {
        // Bytes taken from a real Stocks cache: GC=F, ^JKSE, BTC-USD, BBCA.JK, IDR=X, ^IXIC
        let blob = Data("j\u{04}GC=Fj\u{05}^JKSEj\u{07}BTC-USDj\u{07}BBCA.JKj\u{05}IDR=Xj\u{05}^IXIC".utf8)
        precondition(StocksWatchlist.stringArray(blob) == ["GC=F", "^JKSE", "BTC-USD", "BBCA.JK", "IDR=X", "^IXIC"])
        // A single-string field (the list name, tag 0x32) is not a symbol array
        precondition(StocksWatchlist.stringArray(Data("2\nMy Symbols".utf8)) == nil)
        // Truncated data is rejected
        precondition(StocksWatchlist.stringArray(Data("j\u{09}GC=F".utf8)) == nil)
        precondition(StocksWatchlist.stringArray(Data()) == nil)
        print("Stocks watchlist: 4 cases passed")
        // Optional smoke check against this Mac's Stocks data
        if CommandLine.arguments.contains("--live") { print(StocksWatchlist.read() as Any) }
    }
}
