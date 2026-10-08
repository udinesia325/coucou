import AppKit
import SwiftUI

// MARK: - Quotes (Yahoo Finance chart API, gold-api.com for spot gold)

struct Quote: Identifiable, Equatable, Sendable {
    let symbol: String
    let name: String
    let price: Double
    let previousClose: Double
    let closes: [Double]
    var id: String { symbol }
    var change: Double { price - previousClose }
}

@MainActor
final class MarketsStore: ObservableObject {
    static let shared = MarketsStore()

    /// Fallback when the Stocks app watchlist can't be read.
    static let defaultWatchlist = ["GC=F", "^JKSE", "BTC-USD", "BBCA.JK", "IDR=X", "^IXIC"]
    // ponytail: fixed rates list; make it editable if more pairs are wanted.
    static let rates: [(symbol: String, label: String)] = [
        ("USDIDR=X", "USD/IDR"), ("EURIDR=X", "EUR/IDR"), ("SGDIDR=X", "SGD/IDR"), ("JPYIDR=X", "JPY/IDR"),
    ]

    /// One instrument on the World indexes / FX slides.
    struct Ticker: Identifiable, Sendable {
        let symbol: String     // Yahoo symbol
        let label: String
        let sub: String
        /// Fixed decimals (FX majors); nil = Stocks style (none from 1,000 up, two below).
        var digits: Int? = nil
        var id: String { symbol }
    }

    static let indexGroups: [(title: String, tickers: [Ticker])] = [
        ("Asia", [Ticker(symbol: "^JKSE", label: "IHSG", sub: "🇮🇩 Indonesia"),
                  Ticker(symbol: "^N225", label: "Nikkei 225", sub: "🇯🇵 Japan"),
                  Ticker(symbol: "^KS11", label: "KOSPI", sub: "🇰🇷 Korea"),
                  Ticker(symbol: "000001.SS", label: "SSE Composite", sub: "🇨🇳 China")]),
        ("United States", [Ticker(symbol: "^GSPC", label: "S&P 500", sub: "🇺🇸 500 large caps"),
                           Ticker(symbol: "^IXIC", label: "Nasdaq", sub: "🇺🇸 Composite"),
                           Ticker(symbol: "^DJI", label: "Dow Jones", sub: "🇺🇸 30 industrials")]),
        ("Europe", [Ticker(symbol: "^FTSE", label: "FTSE 100", sub: "🇬🇧 London"),
                    Ticker(symbol: "^GDAXI", label: "DAX", sub: "🇩🇪 Frankfurt"),
                    Ticker(symbol: "^FCHI", label: "CAC 40", sub: "🇫🇷 Paris"),
                    Ticker(symbol: "^STOXX50E", label: "Euro Stoxx 50", sub: "🇪🇺 Eurozone")]),
    ]

    static let fxGroups: [(title: String, tickers: [Ticker])] = [
        ("Forex", [Ticker(symbol: "EURUSD=X", label: "EUR/USD", sub: "Euro", digits: 4),
                   Ticker(symbol: "GBPUSD=X", label: "GBP/USD", sub: "Cable", digits: 4),
                   Ticker(symbol: "JPY=X", label: "USD/JPY", sub: "Yen"),
                   Ticker(symbol: "AUDUSD=X", label: "AUD/USD", sub: "Aussie", digits: 4)]),
        // ponytail: Yahoo has no spot metals or Brent; front-month futures stand in (price +
        // intraday line). Spot gold/silver from gold-api.com replaces the price when it answers.
        ("Commodities", [Ticker(symbol: "GC=F", label: "XAU/USD", sub: "Gold"),
                         Ticker(symbol: "SI=F", label: "XAG/USD", sub: "Silver"),
                         Ticker(symbol: "BZ=F", label: "XBR/USD", sub: "Brent oil")]),
        ("Crypto", [Ticker(symbol: "BTC-USD", label: "BTC", sub: "Bitcoin"),
                    Ticker(symbol: "ETH-USD", label: "ETH", sub: "Ethereum"),
                    Ticker(symbol: "SOL-USD", label: "SOL", sub: "Solana")]),
    ]

    /// Quotes for the World indexes / FX slides, by Yahoo symbol.
    @Published private(set) var board: [String: Quote] = [:]
    @Published private(set) var silverSpot: Double?

    @Published private(set) var watchlist: [Quote] = []
    @Published private(set) var rates: [Quote] = []
    @Published private(set) var goldSpot: Double?
    @Published private(set) var fromStocksApp = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var failed = false

    /// Refreshes the visible slide every 60 s while the Markets tab is on screen.
    func run(page: Int = 0) async {
        while !Task.isCancelled {
            switch page {
            case 1: await refreshBoard(Self.indexGroups)
            case 2: await refreshBoard(Self.fxGroups)
            default: await refresh()
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    private func refreshBoard(_ groups: [(title: String, tickers: [Ticker])]) async {
        let symbols = groups.flatMap { $0.tickers.map(\.symbol) }
        let metals = groups.contains { $0.title == "Commodities" }
        async let list = Self.quotes(symbols)
        async let gold = metals ? Self.goldPrice() : nil
        async let silver = metals ? Self.spotPrice("XAG") : nil
        let (quotes, g, sv) = await (list, gold, silver)
        for q in quotes { board[q.symbol] = q }
        if let g { goldSpot = g }
        if let sv { silverSpot = sv }
        failed = quotes.isEmpty
        lastUpdate = Date()
    }

    func refresh() async {
        let saved = StocksWatchlist.read()
        fromStocksApp = saved != nil
        let symbols = saved ?? Self.defaultWatchlist
        async let list = Self.quotes(symbols)
        async let fx = Self.quotes(Self.rates.map(\.symbol))
        async let gold = Self.goldPrice()
        let (w, r, g) = await (list, fx, gold)
        if !w.isEmpty { watchlist = w }
        if !r.isEmpty { rates = r }
        if let g { goldSpot = g }
        failed = w.isEmpty && r.isEmpty
        lastUpdate = Date()
    }

    /// Quotes in the order of `symbols`; symbols Yahoo doesn't know are dropped.
    nonisolated static func quotes(_ symbols: [String]) async -> [Quote] {
        await withTaskGroup(of: (Int, Quote?).self) { group in
            for (i, s) in symbols.enumerated() {
                group.addTask { (i, await quote(s)) }
            }
            var found: [(Int, Quote)] = []
            for await (i, q) in group { if let q { found.append((i, q)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    nonisolated static func quote(_ symbol: String) async -> Quote? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-.="))) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=5m") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")   // Yahoo rejects empty agents
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double else { return nil }
        let previous = meta["chartPreviousClose"] as? Double ?? meta["previousClose"] as? Double ?? price
        let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first
        let closes = (quote?["close"] as? [Any])?.compactMap { $0 as? Double } ?? []
        let name = meta["longName"] as? String ?? meta["shortName"] as? String ?? symbol
        return Quote(symbol: symbol, name: name, price: price, previousClose: previous, closes: closes)
    }

    nonisolated static func goldPrice() async -> Double? { await spotPrice("XAU") }

    nonisolated static func spotPrice(_ metal: String) async -> Double? {
        guard let url = URL(string: "https://api.gold-api.com/price/\(metal)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["price"] as? Double
    }

    /// The Stocks app shows a few indexes under a short name.
    static func displaySymbol(_ s: String) -> String {
        ["^IXIC": "NASDAQ", "^GSPC": "S&P 500", "^DJI": "DOW J", "^JKSE": "^JKSE"][s] ?? s
    }

    /// Stocks-app style: no decimals from 1,000 up, two below; grouping follows the Mac's locale.
    static func format(_ v: Double, signed: Bool = false, digits fixed: Int? = nil) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let digits = fixed ?? (abs(v) >= 1000 ? 0 : 2)
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        if signed { f.positivePrefix = "+" }
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

// MARK: - Markets view

struct MarketsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store = MarketsStore.shared
    /// 0 watchlist, 1 world indexes, 2 forex · commodities · crypto.
    @State private var page = 0

    private var active: Bool { state.mode == .expanded && state.view == .markets }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            // [‹] cards [›]: the arrows hug the left and right edges, the cards fill the middle.
            HStack(spacing: 4) {
                pagerButton("chevron.left") { (page + 2) % 3 }
                Group {
                    switch page {
                    case 1: board(MarketsStore.indexGroups)
                    case 2: board(MarketsStore.fxGroups)
                    default: watchlistSlide
                    }
                }
                .id(page)
                .transition(.opacity)
                .frame(maxWidth: .infinity)
                pagerButton("chevron.right") { (page + 1) % 3 }
            }
            .padding(.leading, 80)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
        }
        // Page dots stay top right on every slide (beside "Kurs & Gold" on the first).
        .overlay(alignment: .topTrailing) { pagerDots.padding(.trailing, 30).padding(.top, 16) }
        .task(id: active ? page : -1) {
            if active { await store.run(page: page) }
        }
    }

    // MARK: Pager (loops)

    private var pagerDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.white.opacity(i == page ? 0.85 : 0.22)).frame(width: 4.5, height: 4.5)
            }
        }
        .allowsHitTesting(false)
    }

    /// Full-height edge button: a big target at each side of the cards.
    private func pagerButton(_ icon: String, to target: @escaping () -> Int) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) { page = target() }
        }) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .frame(width: 18)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Slide 1 — watchlist (unchanged)

    private var watchlistSlide: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Watchlist").font(.system(size: 11, weight: .semibold))
                    Text(store.fromStocksApp ? "from Stocks" : "default list")
                        .font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079"))
                    Spacer()
                    if let t = store.lastUpdate {
                        Text(t, style: .time).font(.system(size: 9.5)).foregroundColor(Color(hex: "#6B7079"))
                    }
                }
                if store.watchlist.isEmpty {
                    Text(store.failed ? "Can't reach Yahoo Finance." : "Loading quotes…")
                        .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 2) {
                            ForEach(store.watchlist) { QuoteRow(quote: $0) }
                        }
                    }
                }
            }
            ratesColumn.frame(width: 150)
        }
    }

    // MARK: Slides 2 and 3 — one column per group (the group titles head the slide)

    private func board(_ groups: [(title: String, tickers: [MarketsStore.Ticker])]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(groups.indices, id: \.self) { i in
                let group = groups[i]
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title.uppercased())
                        .font(.system(size: 8.5, weight: .bold)).tracking(0.6)
                        .foregroundColor(Color(hex: "#6B7079"))
                        .padding(.bottom, 3)
                    ForEach(group.tickers) { t in
                        BoardRow(ticker: t, quote: store.board[t.symbol], spot: spot(t))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        // Group titles line up with the pager, rows start below it.
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func spot(_ t: MarketsStore.Ticker) -> Double? {
        switch t.symbol {
        case "GC=F": return store.goldSpot
        case "SI=F": return store.silverSpot
        default: return nil
        }
    }

    private var ratesColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Kurs & Gold").font(.system(size: 11, weight: .semibold))
            rateLine("XAU/USD", store.goldSpot.map { MarketsStore.format($0) }, change: nil, accent: "#F5A524")
            ForEach(store.rates) { q in
                rateLine(MarketsStore.rates.first { $0.symbol == q.symbol }?.label ?? q.symbol,
                         MarketsStore.format(q.price), change: q.change, accent: nil)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
    }

    private func rateLine(_ label: String, _ value: String?, change: Double?, accent: String?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10.5, weight: .medium))
                .foregroundColor(accent.map { Color(hex: $0) } ?? Color(hex: "#C5C8CD"))
            Spacer(minLength: 2)
            Text(value ?? "—").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            if let change {
                Image(systemName: change >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 6))
                    .foregroundColor(change >= 0 ? Color(hex: "#34D399") : Color(hex: "#F4505E"))
            }
        }
        .lineLimit(1)
    }
}

/// One row like the Stocks widget: symbol + name, intraday sparkline, price + change.
private struct QuoteRow: View {
    let quote: Quote

    private var color: Color { quote.change >= 0 ? Color(hex: "#34D399") : Color(hex: "#F4505E") }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(MarketsStore.displaySymbol(quote.symbol)).font(.system(size: 11.5, weight: .bold))
                Text(quote.name).font(.system(size: 9.5)).foregroundColor(Color(hex: "#8E939C"))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Sparkline(values: quote.closes, baseline: quote.previousClose, color: color)
                .frame(width: 40, height: 20)
            VStack(alignment: .trailing, spacing: 1) {
                Text(MarketsStore.format(quote.price)).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                Text(MarketsStore.format(quote.change, signed: true))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(color)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
    }
}

/// Compact row for the World indexes / FX slides: label, sparkline, price and % change.
private struct BoardRow: View {
    let ticker: MarketsStore.Ticker
    let quote: Quote?
    var spot: Double?

    private var pct: Double? {
        guard let q = quote, q.previousClose != 0 else { return nil }
        return q.change / q.previousClose * 100
    }
    private var color: Color { (pct ?? 0) >= 0 ? Color(hex: "#34D399") : Color(hex: "#F4505E") }

    var body: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 0) {
                Text(ticker.label).font(.system(size: 10.5, weight: .bold))
                Text(ticker.sub).font(.system(size: 8.5)).foregroundColor(Color(hex: "#8E939C"))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let q = quote {
                Sparkline(values: q.closes, baseline: q.previousClose, color: color)
                    .frame(width: 26, height: 14)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text((spot ?? quote?.price).map { MarketsStore.format($0, digits: ticker.digits) } ?? "—")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                Text(pct.map { String(format: "%+.2f%%", $0) } ?? " ")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundColor(color)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.vertical, 1.5)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
    }
}

/// Intraday line with a dashed previous-close baseline and a soft fill, Stocks style.
private struct Sparkline: View {
    let values: [Double]
    let baseline: Double
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let lo = min(values.min() ?? baseline, baseline), hi = max(values.max() ?? baseline, baseline)
            let span = max(hi - lo, abs(baseline) * 0.0005, 0.000001)
            func y(_ v: Double) -> CGFloat { size.height * CGFloat(1 - (v - lo) / span) }
            var base = Path()
            base.move(to: CGPoint(x: 0, y: y(baseline)))
            base.addLine(to: CGPoint(x: size.width, y: y(baseline)))
            ctx.stroke(base, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: y(v))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0)]),
                                                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), lineWidth: 1.2)
        }
    }
}
