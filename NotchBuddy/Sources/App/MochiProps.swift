import QuartzCore
import SwiftUI

// MARK: - Contextual props (what Mochi wears in each island tab)

/// Mochi dresses for the tab it sits in: headphones for music, a trader's visor and coins
/// for markets, glasses and a live chart for stats… Main Mochi only, expanded island only.
/// On these tabs the prop replaces the outfit chosen in the wardrobe; Home keeps the outfit.
enum MochiProp: Equatable {
    case none, chat, analyst, courier, clipboard, headphones, calendar, candles, memo, hardHat

    static func forView(_ view: IslandView) -> MochiProp {
        switch view {
        case .prompt:    return .chat
        case .stats:     return .analyst
        case .shelf:     return .courier
        case .clipboard: return .clipboard
        case .spotify:   return .headphones
        case .today:     return .calendar
        case .markets:   return .candles
        case .notes:     return .memo
        case .settings:  return .hardHat
        default:         return .none
        }
    }

    /// Wardrobe piece worn with the prop.
    var outfit: Outfit {
        switch self {
        case .analyst: return .roundGlasses
        default:       return .none
        }
    }
}

/// Remembers when the prop changed so the new one pops in. Mutated while drawing, never observed.
final class MochiPropState {
    private var prop: MochiProp = .none
    private var since: Double = 0

    private var grooveLevel: CGFloat = 0
    private var lastNow: Double = 0

    /// 0 → 1 over 0.4 s after a change.
    func presence(of p: MochiProp, now: Double) -> CGFloat {
        if p != prop { prop = p; since = now }
        return CGFloat(min(1, max(0, (now - since) / 0.4)))
    }

    /// 0 → 1 over 0.3 s once media plays, back to 0 over 0.5 s: how much Mochi is dancing.
    func groove(playing: Bool, now: Double) -> CGFloat {
        let dt = CGFloat(min(0.1, max(0, now - lastNow)))
        lastNow = now
        grooveLevel = playing ? min(1, grooveLevel + dt / 0.3) : max(0, grooveLevel - dt / 0.5)
        return grooveLevel
    }
}

extension MochiProp {
    /// Draws in Mochi's canvas, following the body's squash, tilt and head turn.
    @MainActor
    func draw(in context: GraphicsContext, engine: BotEngine, size: CGSize,
              now t: Double, presence: CGFloat, accent: Color, groove: CGFloat = 0) {
        guard self != .none, engine.morph < 0.3, presence > 0 else { return }
        let R = size.width * 0.3, rx = R * 1.14, ry = R * 0.88
        let c = engine.bodyCenter(size: size)
        var ctx = outfitBodyTransform(context: context, cx: c.x, cy: c.y,
                                      tilt: engine.tilt, sx: engine.sx, sy: engine.sy)
        ctx.translateBy(x: sin(engine.yaw) * rx * 0.18, y: 0)   // turn a little with the head
        ctx.opacity = Double(min(1, presence * 2.5))
        let pop = Ease.back(presence)
        let bob = CGFloat(sin(t * 2.4)) * R * 0.05                 // floating things breathe

        switch self {
        case .none:
            break

        case .chat:
            // Speech bubble with typing dots, floating above the head.
            var g = Self.popped(ctx, at: CGPoint(x: rx * 0.5, y: -ry * 1.6), pop)
            g.translateBy(x: 0, y: bob)
            let box = CGRect(x: -rx * 0.05, y: -ry * 2.05, width: R * 1.15, height: R * 0.62)
            var bubble = Path(roundedRect: box, cornerRadius: R * 0.24)
            bubble.move(to: CGPoint(x: box.minX + R * 0.22, y: box.maxY - 1))
            bubble.addLine(to: CGPoint(x: box.minX + R * 0.08, y: box.maxY + R * 0.22))
            bubble.addLine(to: CGPoint(x: box.minX + R * 0.45, y: box.maxY - 1))
            g.fill(bubble, with: .color(.white))
            for i in 0..<3 {
                let jump = max(0, sin(t * 6 - Double(i) * 0.9)) * Double(R) * 0.08
                let d = R * 0.14
                let x = box.midX + CGFloat(i - 1) * R * 0.26
                g.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: box.midY - d / 2 - CGFloat(jump), width: d, height: d)),
                       with: .color(Color(hex: "#5B6170")))
            }

        case .analyst:
            // Round glasses come from the wardrobe; a tiny live bar chart floats beside them.
            var g = Self.popped(ctx, at: CGPoint(x: rx * 0.5, y: -ry * 1.6), pop)
            g.translateBy(x: 0, y: bob)
            let board = CGRect(x: rx * 0.02, y: -ry * 2.1, width: R * 1.0, height: R * 0.72)
            g.fill(Path(roundedRect: board, cornerRadius: R * 0.12), with: .color(Color(hex: "#1E2230")))
            g.stroke(Path(roundedRect: board, cornerRadius: R * 0.12), with: .color(.white.opacity(0.3)), lineWidth: R * 0.04)
            let colors = ["#22D3EE", "#34D399", "#F5A524"]
            for i in 0..<3 {
                let level = 0.35 + 0.55 * (0.5 + 0.5 * sin(t * 2.2 + Double(i) * 1.4))
                let h = CGFloat(level) * board.height * 0.7
                let w = board.width * 0.18
                let x = board.minX + board.width * (0.16 + CGFloat(i) * 0.26)
                g.fill(Path(roundedRect: CGRect(x: x, y: board.maxY - board.height * 0.14 - h, width: w, height: h),
                            cornerRadius: w * 0.3),
                       with: .color(Color(hex: colors[i])))
            }

        case .courier:
            // Brown delivery cap, and a parcel bobbing overhead.
            let g = Self.popped(ctx, at: CGPoint(x: 0, y: -ry), pop)
            let cap = Self.dome(halfWidth: rx * 0.9, base: -ry * 0.5, top: -ry * 1.3)
            g.fill(Self.brim(width: rx * 1.25, y: -ry * 0.5, depth: R * 0.2), with: .color(Color(hex: "#5C3A1A")))
            g.fill(cap, with: .color(Color(hex: "#8B5A2B")))
            g.stroke(cap, with: .color(Color(hex: "#5C3A1A")), lineWidth: R * 0.04)
            Self.parcel(g, center: CGPoint(x: 0, y: -ry * 0.85), side: R * 0.26)
            var p = Self.popped(ctx, at: CGPoint(x: rx * 0.75, y: -ry * 1.7), pop)
            p.translateBy(x: 0, y: bob)
            p.rotate(by: .radians(sin(t * 1.6) * 0.12))
            Self.parcel(p, center: CGPoint(x: rx * 0.75, y: -ry * 1.75), side: R * 0.5)

        case .clipboard:
            // A clipboard held beside Mochi whose rows fill in as things get copied, and a
            // little "copied" card with a check popping up on the other side.
            var board = Self.popped(ctx, at: CGPoint(x: rx * 0.95, y: ry * 0.1), pop)
            board.translateBy(x: rx * 0.95, y: ry * 0.1)
            board.rotate(by: .radians(0.14 + sin(t * 1.5) * 0.03))
            let bw = R * 0.8, bh = R * 1.25
            let frame = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)
            board.fill(Path(roundedRect: frame.offsetBy(dx: R * 0.03, dy: R * 0.05), cornerRadius: R * 0.1), with: .color(.black.opacity(0.3)))
            board.fill(Path(roundedRect: frame, cornerRadius: R * 0.1), with: .color(Color(hex: "#C08A50")))
            board.stroke(Path(roundedRect: frame, cornerRadius: R * 0.1), with: .color(Color(hex: "#8A5A2B")), lineWidth: R * 0.05)
            let paper = CGRect(x: frame.minX + bw * 0.1, y: frame.minY + bh * 0.13, width: bw * 0.8, height: bh * 0.8)
            board.fill(Path(roundedRect: paper, cornerRadius: R * 0.05), with: .color(Color(hex: "#FFFBEF")))
            let cycle = (t * 0.55).truncatingRemainder(dividingBy: 5)       // 4 rows, then a pause
            var rows = board
            rows.opacity = ctx.opacity * (cycle > 4.6 ? (5 - cycle) / 0.4 : 1)
            let tints = ["#7DD3FC", "#F9A8D4", "#86EFAC", "#FDE68A"]
            for i in 0..<4 {
                let y = paper.minY + paper.height * (0.18 + 0.22 * CGFloat(i))
                let p = CGFloat(min(1, max(0, cycle - Double(i))))
                let x0 = paper.minX + paper.width * 0.14, x1 = paper.maxX - paper.width * 0.12
                rows.fill(Path(ellipseIn: CGRect(x: x0 - R * 0.05, y: y - R * 0.05, width: R * 0.1, height: R * 0.1)), with: .color(Color(hex: tints[i])))
                var bar = Path()
                bar.move(to: CGPoint(x: x0 + R * 0.12, y: y))
                bar.addLine(to: CGPoint(x: x0 + R * 0.12 + (x1 - x0 - R * 0.12) * (i == 3 ? p * 0.6 : p), y: y))
                rows.stroke(bar, with: .color(Color(hex: tints[i])), style: StrokeStyle(lineWidth: R * 0.07, lineCap: .round))
            }
            let clip = CGRect(x: -R * 0.2, y: frame.minY - R * 0.1, width: R * 0.4, height: R * 0.24)
            board.fill(Path(roundedRect: clip, cornerRadius: R * 0.07), with: .color(Color(hex: "#D5DAE3")))
            board.stroke(Path(roundedRect: clip, cornerRadius: R * 0.07), with: .color(Color(hex: "#8E96A5")), lineWidth: R * 0.04)
            board.fill(Path(ellipseIn: CGRect(x: -R * 0.05, y: clip.minY + R * 0.06, width: R * 0.1, height: R * 0.1)), with: .color(Color(hex: "#8E96A5")))
            Self.hand(board, at: CGPoint(x: frame.minX + R * 0.02, y: bh * 0.18), r: R * 0.15)

            var card = Self.popped(ctx, at: CGPoint(x: -rx * 0.8, y: -ry * 1.5), pop)
            card.translateBy(x: -rx * 0.8, y: -ry * 1.5 + bob)
            card.rotate(by: .radians(-0.15 + sin(t * 1.2) * 0.05))
            let cs = R * 0.5
            for (dx, dy, col) in [(R * 0.11, -R * 0.11, "#BFD7FF"), (0, 0, "#FFFFFF")] as [(CGFloat, CGFloat, String)] {
                let r = CGRect(x: -cs / 2 + dx, y: -cs / 2 + dy, width: cs, height: cs * 0.85)
                card.fill(Path(roundedRect: r, cornerRadius: R * 0.09), with: .color(Color(hex: col)))
                card.stroke(Path(roundedRect: r, cornerRadius: R * 0.09), with: .color(Color(hex: "#7C93C9")), lineWidth: R * 0.035)
            }
            for i in 0..<2 {
                var line = Path()
                line.move(to: CGPoint(x: -cs * 0.32, y: -cs * 0.14 + CGFloat(i) * cs * 0.22))
                line.addLine(to: CGPoint(x: cs * (i == 0 ? 0.3 : 0.12), y: -cs * 0.14 + CGFloat(i) * cs * 0.22))
                card.stroke(line, with: .color(Color(hex: "#9AA6BF")), style: StrokeStyle(lineWidth: R * 0.05, lineCap: .round))
            }
            var badge = card
            let beat = CGFloat(0.85 + 0.15 * sin(t * 4))
            badge.translateBy(x: cs * 0.5, y: cs * 0.42)
            badge.scaleBy(x: beat, y: beat)
            badge.fill(Path(ellipseIn: CGRect(x: -R * 0.13, y: -R * 0.13, width: R * 0.26, height: R * 0.26)), with: .color(Color(hex: "#22C55E")))
            var tick = Path()
            tick.move(to: CGPoint(x: -R * 0.06, y: 0))
            tick.addLine(to: CGPoint(x: -R * 0.015, y: R * 0.05))
            tick.addLine(to: CGPoint(x: R * 0.07, y: -R * 0.05))
            badge.stroke(tick, with: .color(.white), style: StrokeStyle(lineWidth: R * 0.045, lineCap: .round, lineJoin: .round))

        case .headphones:
            // Chunky headphones with heart badges. While media plays the cups thump on the beat,
            // sound waves ring out and two round hands pump up and down: Mochi dances.
            let beat = Self.beat
            let thump = pow(1 - abs(sin(.pi * beat)), 6) * groove          // peaks as Mochi lands
            let g = Self.popped(ctx, at: CGPoint(x: 0, y: -ry), pop)
            var band = Path()
            band.move(to: CGPoint(x: -rx * 0.92, y: -ry * 0.1))
            band.addCurve(to: CGPoint(x: rx * 0.92, y: -ry * 0.1),
                          control1: CGPoint(x: -rx * 1.0, y: -ry * 1.8), control2: CGPoint(x: rx * 1.0, y: -ry * 1.8))
            g.stroke(band, with: .color(Color(hex: "#3A3F5C")), style: StrokeStyle(lineWidth: R * 0.2, lineCap: .round))
            g.stroke(band.applying(CGAffineTransform(translationX: 0, y: -R * 0.04)),
                     with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: R * 0.05, lineCap: .round))
            for sd: CGFloat in [-1, 1] {
                var c = g
                c.translateBy(x: sd * rx * 0.97, y: ry * 0.18)
                let k = 1 + 0.12 * thump
                c.scaleBy(x: k, y: k)
                if groove > 0.02 {
                    for w in 0..<2 {
                        var arc = Path()
                        arc.addArc(center: .zero, radius: R * (0.36 + 0.12 * CGFloat(w)) + R * 0.08 * thump,
                                   startAngle: .degrees(sd > 0 ? -38 : 142), endAngle: .degrees(sd > 0 ? 38 : 218), clockwise: false)
                        var wave = c
                        wave.opacity = ctx.opacity * Double(groove) * (w == 0 ? 0.75 : 0.4)
                        wave.stroke(arc, with: .color(accent), style: StrokeStyle(lineWidth: R * 0.06, lineCap: .round))
                    }
                }
                let shell = Path(roundedRect: CGRect(x: -R * 0.24, y: -R * 0.4, width: R * 0.48, height: R * 0.8), cornerRadius: R * 0.24)
                c.fill(shell, with: .color(accent))
                c.stroke(shell, with: .color(.black.opacity(0.22)), lineWidth: R * 0.05)
                c.fill(Path(ellipseIn: CGRect(x: -R * 0.15, y: -R * 0.32, width: R * 0.14, height: R * 0.26)), with: .color(.white.opacity(0.42)))
                Self.heart(c, center: CGPoint(x: 0, y: R * 0.1), size: R * 0.22, color: .white.opacity(0.95))
            }
            if groove > 0.02 {
                for sd: CGFloat in [-1, 1] {
                    var h = ctx
                    h.opacity = ctx.opacity * Double(min(1, groove * 1.5))
                    let swing = sin(.pi * beat + (sd > 0 ? .pi : 0))        // the arms alternate
                    Self.hand(h, at: CGPoint(x: sd * (rx + R * 0.27), y: ry * 0.55 - (0.5 + 0.5 * swing) * R * 0.85), r: R * 0.15)
                }
            }
            let tints = [accent, Color(hex: "#22D3EE"), Color(hex: "#FACC15")]
            let spots: [CGFloat] = [0.85, -0.9, 0.05]
            for k in 0..<3 {
                let ph = CGFloat((t * (groove > 0.02 ? 0.8 : 0.45) + Double(k) / 3).truncatingRemainder(dividingBy: 1))
                var n = ctx
                n.opacity = ctx.opacity * Double(sin(ph * .pi))
                n.draw(Text(k == 1 ? "♫" : "♪").font(.system(size: R * 0.42, weight: .bold)).foregroundColor(tints[k]),
                       at: CGPoint(x: spots[k] * rx + CGFloat(sin(t * 2 + Double(k))) * R * 0.08, y: -ry * 1.5 - ph * R * 0.9))
            }

        case .calendar:
            // Mochi holds today's calendar page in one hand and sips a steaming coffee from the other.
            var page = Self.popped(ctx, at: CGPoint(x: rx * 0.95, y: ry * 0.05), pop)
            page.translateBy(x: rx * 0.95, y: ry * 0.05)
            page.rotate(by: .radians(0.12 + sin(t * 1.4) * 0.03))
            let pw = R * 0.8, ph = R * 0.88
            let sheet = CGRect(x: -pw / 2, y: -ph / 2, width: pw, height: ph)
            let sheetPath = Path(roundedRect: sheet, cornerRadius: R * 0.12)
            page.fill(Path(roundedRect: sheet.offsetBy(dx: R * 0.03, dy: R * 0.05), cornerRadius: R * 0.12), with: .color(.black.opacity(0.3)))
            page.fill(sheetPath, with: .color(.white))
            var head = page
            head.clip(to: sheetPath)
            head.fill(Path(CGRect(x: sheet.minX, y: sheet.minY, width: pw, height: ph * 0.3)), with: .color(Color(hex: "#F4505E")))
            for ringX: CGFloat in [-0.22, 0.22] {
                let ring = CGRect(x: ringX * pw - R * 0.05, y: sheet.minY - R * 0.06, width: R * 0.1, height: R * 0.2)
                page.fill(Path(roundedRect: ring, cornerRadius: R * 0.05), with: .color(Color(hex: "#3A3F5C")))
            }
            let day = Calendar.current.component(.day, from: Date())
            page.draw(Text("\(day)").font(.system(size: R * 0.46, weight: .heavy, design: .rounded)).foregroundColor(Color(hex: "#2B2F3A")),
                      at: CGPoint(x: 0, y: ph * 0.17))
            Self.hand(page, at: CGPoint(x: sheet.minX + R * 0.02, y: ph * 0.2), r: R * 0.15)

            // The mug rises toward Mochi now and then, as if for a sip.
            let sip = CGFloat(pow(max(0, sin(t * 0.9)), 3))
            var mug = Self.popped(ctx, at: CGPoint(x: -rx * 0.9, y: ry * 0.2), pop)
            mug.translateBy(x: -rx * 0.9 + sip * R * 0.06, y: ry * 0.2 - sip * R * 0.16)
            mug.rotate(by: .radians(Double(-sip) * 0.14))
            let mw = R * 0.6, mh = R * 0.54
            var handle = Path()
            handle.addArc(center: CGPoint(x: -mw / 2, y: 0), radius: mh * 0.3, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            mug.stroke(handle, with: .color(Color(hex: "#E8C99B")), style: StrokeStyle(lineWidth: R * 0.07, lineCap: .round))
            let cup = Path(roundedRect: CGRect(x: -mw / 2, y: -mh / 2, width: mw, height: mh), cornerRadius: R * 0.13)
            mug.fill(Path(roundedRect: CGRect(x: -mw / 2 + R * 0.03, y: -mh / 2 + R * 0.05, width: mw, height: mh), cornerRadius: R * 0.13),
                     with: .color(.black.opacity(0.28)))
            mug.fill(cup, with: .color(Color(hex: "#FFF1DC")))
            mug.stroke(cup, with: .color(Color(hex: "#D9B48A")), lineWidth: R * 0.04)
            Self.heart(mug, center: CGPoint(x: 0, y: R * 0.02), size: R * 0.18, color: Color(hex: "#F4505E"))
            for i in 0..<2 {
                var steam = Path()
                let x0 = (i == 0 ? -1 : 1) * mw * 0.2
                for k in 0...8 {
                    let f = CGFloat(k) / 8
                    let pt = CGPoint(x: x0 + CGFloat(sin(t * 3 + Double(f) * 5 + Double(i) * 2)) * R * 0.06, y: -mh / 2 - f * R * 0.5)
                    if k == 0 { steam.move(to: pt) } else { steam.addLine(to: pt) }
                }
                var sg = mug
                sg.opacity = ctx.opacity * (0.7 + 0.2 * Double(sin(t * 2 + Double(i))))
                sg.stroke(steam, with: .color(Color(hex: "#9FB0D0")), style: StrokeStyle(lineWidth: R * 0.05, lineCap: .round, lineJoin: .round))
            }
            Self.hand(mug, at: CGPoint(x: -mw / 2 - mh * 0.3, y: 0), r: R * 0.14)

        case .candles:
            // Cartoon OHLC candlesticks growing above the head. The last one is live.
            let g = Self.popped(ctx, at: CGPoint(x: 0, y: -ry * 1.2), pop)
            let w = R * 0.25, gap = R * 0.4, chart = R * 1.7, base = -ry * 1.15
            // (open, close, high, low) as a share of the chart height
            var data: [(o: CGFloat, c: CGFloat, h: CGFloat, l: CGFloat)] =
                [(0.30, 0.20, 0.36, 0.14), (0.20, 0.40, 0.46, 0.16), (0.40, 0.32, 0.50, 0.26),
                 (0.32, 0.58, 0.66, 0.28), (0.52, 0.52, 0.0, 0.0)]
            data[4].c = 0.74 + 0.12 * CGFloat(sin(t * 2.6))
            data[4].h = data[4].c + 0.05
            data[4].l = 0.46
            var floor = Path()
            floor.move(to: CGPoint(x: -2.6 * gap, y: base + R * 0.05))
            floor.addLine(to: CGPoint(x: 2.6 * gap, y: base + R * 0.05))
            g.stroke(floor, with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: R * 0.05, lineCap: .round))
            for (i, d) in data.enumerated() {
                let x = (CGFloat(i) - 2) * gap
                let bounce = CGFloat(sin(t * 3 + Double(i) * 0.7)) * R * 0.035
                let up = d.c >= d.o
                let fill = Color(hex: up ? "#34D399" : "#F4505E"), edge = Color(hex: up ? "#15803D" : "#B91C3B")
                func y(_ v: CGFloat) -> CGFloat { base - v * chart + bounce }
                var wick = Path()
                wick.move(to: CGPoint(x: x, y: y(d.h)))
                wick.addLine(to: CGPoint(x: x, y: y(d.l)))
                g.stroke(wick, with: .color(edge), style: StrokeStyle(lineWidth: R * 0.06, lineCap: .round))
                let top = y(max(d.o, d.c)), bottom = y(min(d.o, d.c))
                let body = CGRect(x: x - w / 2, y: top, width: w, height: max(R * 0.14, bottom - top))
                let shape = Path(roundedRect: body, cornerRadius: w * 0.42)
                g.fill(shape, with: .color(fill))
                g.stroke(shape, with: .color(edge), lineWidth: R * 0.045)
                g.fill(Path(roundedRect: CGRect(x: body.minX + w * 0.16, y: body.minY + w * 0.14, width: w * 0.16, height: min(body.height * 0.4, w * 0.7)),
                            cornerRadius: w * 0.08), with: .color(.white.opacity(0.45)))
                if body.height > R * 0.3 {                                   // the tall ones have faces
                    for sd: CGFloat in [-1, 1] {
                        let e = w * 0.1
                        g.fill(Path(ellipseIn: CGRect(x: x + sd * w * 0.17 - e, y: body.minY + body.height * 0.34 - e, width: e * 2, height: e * 2.4)),
                               with: .color(Color(hex: "#1E2230")))
                    }
                }
            }
            Self.sparkle(g, center: CGPoint(x: 2 * gap + R * 0.32, y: base - 0.95 * chart),
                         r: R * 0.13 * (0.8 + 0.2 * CGFloat(sin(t * 5))), color: Color(hex: "#FACC15"))

        case .memo:
            // Mochi holds a memo pad against its belly and ticks off to-dos with a pencil.
            var pad = Self.popped(ctx, at: CGPoint(x: 0, y: ry * 0.9), pop)
            pad.translateBy(x: rx * 0.12, y: ry * 1.05)
            pad.rotate(by: .radians(-0.1 + sin(t * 1.4) * 0.02))
            let pw = R * 1.3, ph = R * 1.0
            let sheet = CGRect(x: -pw / 2, y: -ph / 2, width: pw, height: ph)
            let paper = Path(roundedRect: sheet, cornerRadius: R * 0.1)
            pad.fill(Path(roundedRect: sheet.offsetBy(dx: R * 0.03, dy: R * 0.05), cornerRadius: R * 0.1), with: .color(.black.opacity(0.3)))
            pad.fill(paper, with: .color(Color(hex: "#FFF6D5")))
            pad.stroke(paper, with: .color(Color(hex: "#E3CD8C")), lineWidth: R * 0.04)
            for sx: CGFloat in [-0.3, 0, 0.3] {
                pad.fill(Path(ellipseIn: CGRect(x: sx * pw - R * 0.05, y: sheet.minY - R * 0.04, width: R * 0.1, height: R * 0.1)),
                         with: .color(Color(hex: "#6B7280")))
            }
            let cycle = (t * 0.6).truncatingRemainder(dividingBy: 4)       // 3 to-dos, then a pause
            let fade = cycle > 3.6 ? (4 - cycle) / 0.4 : 1
            var rows = pad
            rows.opacity = ctx.opacity * fade
            var tip = CGPoint(x: sheet.maxX - pw * 0.1, y: sheet.maxY - ph * 0.12)
            for i in 0..<3 {
                let rowY = sheet.minY + ph * (0.3 + 0.24 * CGFloat(i))
                let x0 = sheet.minX + pw * 0.3, x1 = sheet.minX + pw * 0.86
                let p = CGFloat(min(1, max(0, cycle - Double(i))))
                let box = CGRect(x: sheet.minX + pw * 0.1, y: rowY - R * 0.08, width: R * 0.16, height: R * 0.16)
                rows.stroke(Path(roundedRect: box, cornerRadius: R * 0.04), with: .color(Color(hex: "#9CA3AF")), lineWidth: R * 0.035)
                var dash = Path()
                dash.move(to: CGPoint(x: x0, y: rowY))
                dash.addLine(to: CGPoint(x: x0 + (x1 - x0) * p, y: rowY))
                rows.stroke(dash, with: .color(Color(hex: "#8B93A5")), style: StrokeStyle(lineWidth: R * 0.055, lineCap: .round))
                if p >= 1 {
                    var tick = Path()
                    tick.move(to: CGPoint(x: box.minX + box.width * 0.18, y: box.midY))
                    tick.addLine(to: CGPoint(x: box.minX + box.width * 0.42, y: box.maxY - box.height * 0.2))
                    tick.addLine(to: CGPoint(x: box.maxX + box.width * 0.1, y: box.minY - box.height * 0.1))
                    rows.stroke(tick, with: .color(Color(hex: "#22C55E")), style: StrokeStyle(lineWidth: R * 0.06, lineCap: .round, lineJoin: .round))
                }
                if cycle >= Double(i) && cycle < Double(i + 1) {
                    tip = CGPoint(x: x0 + (x1 - x0) * p, y: rowY + CGFloat(sin(t * 20)) * R * 0.012)
                }
            }
            Self.hand(pad, at: CGPoint(x: sheet.minX - R * 0.02, y: ph * 0.18), r: R * 0.16)
            var pen = pad
            pen.translateBy(x: tip.x, y: tip.y)
            pen.rotate(by: .radians(0.62))
            let len = R * 0.95, pwid = R * 0.17, tipLen = R * 0.2
            pen.fill(Path(CGRect(x: -pwid / 2, y: -len, width: pwid, height: len - tipLen)), with: .color(Color(hex: "#F7C948")))
            pen.fill(Path(CGRect(x: -pwid / 6, y: -len, width: pwid / 3, height: len - tipLen)), with: .color(Color(hex: "#E5B23A")))
            pen.fill(Path(roundedRect: CGRect(x: -pwid / 2, y: -len - pwid * 0.45, width: pwid, height: pwid * 0.6), cornerRadius: pwid * 0.25),
                     with: .color(Color(hex: "#F28AA5")))
            var nib = Path()
            nib.move(to: CGPoint(x: -pwid / 2, y: -tipLen))
            nib.addLine(to: CGPoint(x: pwid / 2, y: -tipLen))
            nib.addLine(to: .zero)
            nib.closeSubpath()
            pen.fill(nib, with: .color(Color(hex: "#F1D2A8")))
            pen.fill(Path(CGRect(x: -pwid * 0.17, y: -tipLen * 0.4, width: pwid * 0.34, height: tipLen * 0.4)), with: .color(Color(hex: "#3B3F47")))
            Self.hand(pen, at: CGPoint(x: 0, y: -len * 0.72), r: R * 0.15)

        case .hardHat:
            // Yellow hard hat for the settings workshop, a gear turning above.
            let g = Self.popped(ctx, at: CGPoint(x: 0, y: -ry), pop)
            let hat = Self.dome(halfWidth: rx * 0.88, base: -ry * 0.48, top: -ry * 1.35)
            g.fill(Self.brim(width: rx * 1.15, y: -ry * 0.48, depth: R * 0.16), with: .color(Color(hex: "#E0A800")))
            g.fill(hat, with: .color(Color(hex: "#F5C518")))
            var ridge = Path()
            ridge.move(to: CGPoint(x: 0, y: -ry * 1.12))
            ridge.addLine(to: CGPoint(x: 0, y: -ry * 0.55))
            g.stroke(ridge, with: .color(Color(hex: "#E0A800")), style: StrokeStyle(lineWidth: R * 0.12, lineCap: .round))
            g.stroke(hat, with: .color(Color(hex: "#C99700")), lineWidth: R * 0.04)
            var gear = Self.popped(ctx, at: CGPoint(x: rx * 0.75, y: -ry * 1.8), pop)
            gear.translateBy(x: rx * 0.75, y: -ry * 1.8 + bob)
            gear.rotate(by: .radians(t * 1.2))
            let r = R * 0.2
            for i in 0..<8 {
                var tooth = gear
                tooth.rotate(by: .radians(Double(i) * .pi / 4))
                tooth.fill(Path(CGRect(x: -r * 0.22, y: -r * 1.35, width: r * 0.44, height: r * 0.5)),
                           with: .color(Color(hex: "#9CA3AF")))
            }
            gear.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)), with: .color(Color(hex: "#9CA3AF")))
            gear.fill(Path(ellipseIn: CGRect(x: -r * 0.4, y: -r * 0.4, width: r * 0.8, height: r * 0.8)),
                      with: .color(Color(hex: "#1E2230")))
        }
    }

    // MARK: Shared shapes

    /// Same clock as `BotEngine.applyDance` (112 BPM), so props move in step with Mochi.
    private static var beat: CGFloat { CGFloat(CACurrentMediaTime()) * 112 / 60 }

    /// Round white hand, like Mochi's own.
    private static func hand(_ ctx: GraphicsContext, at c: CGPoint, r: CGFloat) {
        let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.fill(disc, with: .radialGradient(Gradient(colors: [.white, Color(hex: "#C9CDD6")]),
                                             center: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.35),
                                             startRadius: 0, endRadius: r * 1.5))
        ctx.stroke(disc, with: .color(Color(hex: "#9AA1AF").opacity(0.55)), lineWidth: r * 0.14)
    }

    private static func heart(_ ctx: GraphicsContext, center c: CGPoint, size s: CGFloat, color: Color) {
        let r = s * 0.27
        for sd: CGFloat in [-1, 1] {
            ctx.fill(Path(ellipseIn: CGRect(x: c.x + sd * s * 0.23 - r, y: c.y - s * 0.14 - r, width: r * 2, height: r * 2)), with: .color(color))
        }
        var tri = Path()
        tri.move(to: CGPoint(x: c.x - s * 0.47, y: c.y - s * 0.02))
        tri.addLine(to: CGPoint(x: c.x + s * 0.47, y: c.y - s * 0.02))
        tri.addLine(to: CGPoint(x: c.x, y: c.y + s * 0.5))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(color))
    }

    private static func sparkle(_ ctx: GraphicsContext, center c: CGPoint, r: CGFloat, color: Color) {
        var p = Path()
        for i in 0..<8 {
            let a = Double(i) * .pi / 4 - .pi / 2, rad = i % 2 == 0 ? r : r * 0.35
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }

    /// Scales `ctx` around `anchor` (body coordinates) for the pop-in.
    private static func popped(_ ctx: GraphicsContext, at anchor: CGPoint, _ s: CGFloat) -> GraphicsContext {
        var c = ctx
        c.translateBy(x: anchor.x, y: anchor.y)
        c.scaleBy(x: max(0.001, s), y: max(0.001, s))
        c.translateBy(x: -anchor.x, y: -anchor.y)
        return c
    }

    /// Cap / helmet crown sitting on the head.
    private static func dome(halfWidth w: CGFloat, base: CGFloat, top: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: -w, y: base))
        p.addCurve(to: CGPoint(x: w, y: base),
                   control1: CGPoint(x: -w * 1.02, y: top), control2: CGPoint(x: w * 1.02, y: top))
        p.addQuadCurve(to: CGPoint(x: -w, y: base), control: CGPoint(x: 0, y: base + (base - top) * 0.15))
        p.closeSubpath()
        return p
    }

    private static func brim(width w: CGFloat, y: CGFloat, depth: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: -w, y: y - depth * 0.35, width: w * 2, height: depth))
    }

    private static func parcel(_ ctx: GraphicsContext, center c: CGPoint, side s: CGFloat) {
        let box = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s * 0.85)
        ctx.fill(Path(roundedRect: box, cornerRadius: s * 0.1), with: .color(Color(hex: "#D4A373")))
        ctx.fill(Path(CGRect(x: box.midX - s * 0.09, y: box.minY, width: s * 0.18, height: box.height)),
                 with: .color(Color(hex: "#F1E3C8")))
        ctx.stroke(Path(roundedRect: box, cornerRadius: s * 0.1), with: .color(Color(hex: "#9C6B3E")), lineWidth: s * 0.06)
    }

    /// Gold coin with a $; `flip` (-1…1) squeezes it horizontally as it spins.
    private static func coin(_ ctx: GraphicsContext, center c: CGPoint, r: CGFloat, flip: CGFloat) {
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.scaleBy(x: max(0.12, abs(flip)), y: 1)
        let disc = Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
        g.fill(disc, with: .color(Color(hex: "#F5C542")))
        g.stroke(disc, with: .color(Color(hex: "#C9962B")), lineWidth: r * 0.18)
        if abs(flip) > 0.35 {
            g.draw(Text("$").font(.system(size: r * 1.3, weight: .heavy)).foregroundColor(Color(hex: "#9A6B12")), at: .zero)
        }
    }
}
