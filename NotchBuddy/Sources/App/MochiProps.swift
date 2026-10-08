import SwiftUI

// MARK: - Contextual props (what Mochi wears in each island tab)

/// Mochi dresses for the tab it sits in: headphones for music, a trader's visor and coins
/// for markets, glasses and a live chart for stats… Main Mochi only, expanded island only.
/// On these tabs the prop replaces the outfit chosen in the wardrobe; Home keeps the outfit.
enum MochiProp: Equatable {
    case none, chat, analyst, courier, paperclip, headphones, sunny, trader, pencil, hardHat

    static func forView(_ view: IslandView) -> MochiProp {
        switch view {
        case .prompt:    return .chat
        case .stats:     return .analyst
        case .shelf:     return .courier
        case .clipboard: return .paperclip
        case .spotify:   return .headphones
        case .today:     return .sunny
        case .markets:   return .trader
        case .notes:     return .pencil
        case .settings:  return .hardHat
        default:         return .none
        }
    }

    /// Wardrobe piece worn with the prop.
    var outfit: Outfit {
        switch self {
        case .analyst: return .roundGlasses
        case .sunny:   return .sunglasses
        default:       return .none
        }
    }
}

/// Remembers when the prop changed so the new one pops in. Mutated while drawing, never observed.
final class MochiPropState {
    private var prop: MochiProp = .none
    private var since: Double = 0

    /// 0 → 1 over 0.4 s after a change.
    func presence(of p: MochiProp, now: Double) -> CGFloat {
        if p != prop { prop = p; since = now }
        return CGFloat(min(1, max(0, (now - since) / 0.4)))
    }
}

extension MochiProp {
    /// Draws in Mochi's canvas, following the body's squash, tilt and head turn.
    @MainActor
    func draw(in context: GraphicsContext, engine: BotEngine, size: CGSize,
              now t: Double, presence: CGFloat, accent: Color) {
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

        case .paperclip:
            // A giant paperclip holding Mochi like a sheet of paper.
            var g = Self.popped(ctx, at: CGPoint(x: -rx * 0.45, y: -ry * 0.9), pop)
            g.translateBy(x: -rx * 0.45, y: -ry * 0.95)
            g.rotate(by: .radians(-0.35 + sin(t * 1.3) * 0.04))
            let w = R * 0.42, h = R * 1.15
            var clip = Path()
            clip.move(to: CGPoint(x: -w * 0.2, y: h * 0.18))
            clip.addLine(to: CGPoint(x: -w * 0.2, y: -h * 0.32))
            clip.addArc(center: CGPoint(x: 0, y: -h * 0.32), radius: w * 0.2,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            clip.addLine(to: CGPoint(x: w * 0.2, y: h * 0.32))
            clip.addArc(center: CGPoint(x: -w * 0.05, y: h * 0.32), radius: w * 0.25,
                        startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            clip.addLine(to: CGPoint(x: -w * 0.3, y: -h * 0.42))
            clip.addArc(center: CGPoint(x: 0, y: -h * 0.42), radius: w * 0.3,
                        startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            clip.addLine(to: CGPoint(x: w * 0.3, y: h * 0.05))
            g.stroke(clip, with: .color(Color(hex: "#8A93A3")), style: StrokeStyle(lineWidth: R * 0.1, lineCap: .round, lineJoin: .round))
            g.stroke(clip, with: .color(Color(hex: "#E4E8EE")), style: StrokeStyle(lineWidth: R * 0.045, lineCap: .round, lineJoin: .round))

        case .headphones:
            // Big headphones in the music's color, notes drifting up.
            let g = Self.popped(ctx, at: CGPoint(x: 0, y: -ry), pop)
            var band = Path()
            band.move(to: CGPoint(x: -rx * 0.98, y: -ry * 0.15))
            band.addCurve(to: CGPoint(x: rx * 0.98, y: -ry * 0.15),
                          control1: CGPoint(x: -rx * 1.05, y: -ry * 1.75), control2: CGPoint(x: rx * 1.05, y: -ry * 1.75))
            g.stroke(band, with: .color(Color(hex: "#2A2D34")), style: StrokeStyle(lineWidth: R * 0.17, lineCap: .round))
            g.stroke(band, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: R * 0.05, lineCap: .round))
            for sd: CGFloat in [-1, 1] {
                let cup = CGRect(x: sd * rx - R * 0.2, y: -ry * 0.45, width: R * 0.4, height: R * 0.68)
                g.fill(Path(roundedRect: cup, cornerRadius: R * 0.17), with: .color(accent))
                g.fill(Path(roundedRect: cup.insetBy(dx: R * 0.08, dy: R * 0.12), cornerRadius: R * 0.1),
                       with: .color(.black.opacity(0.22)))
            }
            for k in 0..<2 {
                let ph = CGFloat((t * 0.55 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1))
                let sd: CGFloat = k == 0 ? 1 : -1
                var n = ctx
                n.opacity = ctx.opacity * Double(sin(ph * .pi))
                n.draw(Text(k == 0 ? "♪" : "♫").font(.system(size: R * 0.45, weight: .bold)).foregroundColor(accent),
                       at: CGPoint(x: sd * (rx * 0.8 + ph * R * 0.25), y: -ry * 1.35 - ph * R * 0.9))
            }

        case .sunny:
            // Sunglasses from the wardrobe; a little sun spins overhead.
            var g = Self.popped(ctx, at: CGPoint(x: rx * 0.7, y: -ry * 1.75), pop)
            g.translateBy(x: rx * 0.7, y: -ry * 1.75 + bob)
            g.rotate(by: .radians(t * 0.8))
            let r = R * 0.2
            for i in 0..<8 {
                var ray = g
                ray.rotate(by: .radians(Double(i) * .pi / 4))
                ray.fill(Path(roundedRect: CGRect(x: -r * 0.17, y: -r * 1.75, width: r * 0.34, height: r * 0.5),
                              cornerRadius: r * 0.17),
                         with: .color(Color(hex: "#FFB020")))
            }
            g.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)), with: .color(Color(hex: "#FFC93C")))

        case .trader:
            // Green trader's eyeshade with a $ badge; gold coins flip as they float up.
            let g = Self.popped(ctx, at: CGPoint(x: 0, y: -ry * 0.6), pop)
            var shade = Path()
            shade.move(to: CGPoint(x: -rx * 0.92, y: -ry * 0.62))
            shade.addQuadCurve(to: CGPoint(x: rx * 0.92, y: -ry * 0.62), control: CGPoint(x: 0, y: -ry * 0.76))
            shade.addLine(to: CGPoint(x: rx * 0.78, y: -ry * 0.3))
            shade.addQuadCurve(to: CGPoint(x: -rx * 0.78, y: -ry * 0.3), control: CGPoint(x: 0, y: -ry * 0.12))
            shade.closeSubpath()
            g.fill(shade, with: .color(Color(hex: "#22C55E").opacity(0.6)))
            g.stroke(shade, with: .color(Color(hex: "#15803D")), lineWidth: R * 0.05)
            var band = Path()
            band.move(to: CGPoint(x: -rx * 0.98, y: -ry * 0.62))
            band.addQuadCurve(to: CGPoint(x: rx * 0.98, y: -ry * 0.62), control: CGPoint(x: 0, y: -ry * 0.78))
            g.stroke(band, with: .color(Color(hex: "#166534")), style: StrokeStyle(lineWidth: R * 0.12, lineCap: .round))
            Self.coin(g, center: CGPoint(x: 0, y: -ry * 0.7), r: R * 0.14, flip: 1)
            for k in 0..<3 {
                let ph = CGFloat((t * 0.45 + Double(k) / 3).truncatingRemainder(dividingBy: 1))
                let spots: [CGFloat] = [0.6, -0.65, 0.05]
                let x = spots[k] * rx + CGFloat(sin(t * 2 + Double(k))) * R * 0.06
                var cg = ctx
                cg.opacity = ctx.opacity * Double(sin(ph * .pi))
                Self.coin(cg, center: CGPoint(x: x, y: -ry * 1.25 - ph * R * 1.0), r: R * 0.17,
                          flip: CGFloat(cos(t * 4 + Double(k) * 2)))
            }

        case .pencil:
            // Pencil tucked behind the "ear", sticky note floating on the other side.
            var g = Self.popped(ctx, at: CGPoint(x: rx * 0.85, y: -ry * 0.7), pop)
            g.translateBy(x: rx * 0.88, y: -ry * 0.72)
            g.rotate(by: .radians(0.62 + sin(t * 1.5) * 0.03))
            let len = R * 1.2, w = R * 0.19
            g.fill(Path(CGRect(x: -w / 2, y: -len / 2, width: w, height: len * 0.78)), with: .color(Color(hex: "#F7C948")))
            g.fill(Path(CGRect(x: -w / 6, y: -len / 2, width: w / 3, height: len * 0.78)), with: .color(Color(hex: "#E5B23A")))
            g.fill(Path(roundedRect: CGRect(x: -w / 2, y: -len / 2 - w * 0.5, width: w, height: w * 0.62),
                        cornerRadius: w * 0.25),
                   with: .color(Color(hex: "#F28AA5")))
            g.fill(Path(CGRect(x: -w / 2, y: -len / 2 - w * 0.05, width: w, height: w * 0.3)), with: .color(Color(hex: "#C9CED6")))
            var tip = Path()
            tip.move(to: CGPoint(x: -w / 2, y: len * 0.28))
            tip.addLine(to: CGPoint(x: w / 2, y: len * 0.28))
            tip.addLine(to: CGPoint(x: 0, y: len * 0.5))
            tip.closeSubpath()
            g.fill(tip, with: .color(Color(hex: "#F1D2A8")))
            var lead = Path()
            lead.move(to: CGPoint(x: -w * 0.17, y: len * 0.43))
            lead.addLine(to: CGPoint(x: w * 0.17, y: len * 0.43))
            lead.addLine(to: CGPoint(x: 0, y: len * 0.5))
            lead.closeSubpath()
            g.fill(lead, with: .color(Color(hex: "#3B3F47")))
            var note = Self.popped(ctx, at: CGPoint(x: -rx * 0.7, y: -ry * 1.7), pop)
            note.translateBy(x: -rx * 0.7, y: -ry * 1.7 + bob)
            note.rotate(by: .radians(-0.18 + sin(t * 1.2) * 0.05))
            let s = R * 0.62
            note.fill(Path(CGRect(x: -s / 2, y: -s / 2, width: s, height: s)), with: .color(Color(hex: "#FDE68A")))
            for i in 0..<3 {
                note.fill(Path(CGRect(x: -s * 0.32, y: -s * 0.2 + CGFloat(i) * s * 0.2, width: s * (i == 2 ? 0.4 : 0.64), height: s * 0.06)),
                          with: .color(Color(hex: "#B08D2A").opacity(0.7)))
            }

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
