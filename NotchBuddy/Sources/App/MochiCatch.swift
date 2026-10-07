import SwiftUI

// MARK: - "Mochi caught something" (new clipboard item, file on the shelf)

/// One catch: an icon flies into Mochi, Mochi gulps and chews, a "+1" pops out.
struct CatchEvent: Equatable {
    let id = UUID()
    let icon: String
    let color: String
}

@MainActor
enum MochiCatch {
    static func fire(icon: String, color: String) {
        let state = AppState.shared
        // Hidden island: peek out (silently) so the catch is visible.
        if state.mode == .hidden { NotificationCenter.default.post(name: .musicReveal, object: nil) }
        state.catchEvent = CatchEvent(icon: icon, color: color)
        SoundEngine.shared.play("gulp")
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)   // icon reaches the mouth
            NotificationCenter.default.post(name: .botGulp, object: nil)
            try? await Task.sleep(nanoseconds: 700_000_000)
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        }
    }
}

/// Drawn over the island, in island coordinates; the icon starts below the island
/// (over the desktop) and arcs up into Mochi.
struct CatchBurst: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat
    @State private var event: CatchEvent?
    @State private var start = Date()

    private static let duration = 1.5

    var body: some View {
        let (cx, cy, d, _) = botPosition(mode: state.mode, view: state.view, islandW: islandW,
                                         islandH: islandH, uploadProgress: 0, hasNotch: state.hasNotch)
        TimelineView(.animation(paused: event == nil)) { ctx in
            let e = ctx.date.timeIntervalSince(start)
            let fly = CGFloat(min(1, e / 0.5))                   // 0…1 flight
            let pop = CGFloat(min(1, max(0, (e - 0.45) / 0.9)))  // 0…1 after the swallow
            ZStack {
                if let event {
                    let color = Color(hex: event.color)
                    // The caught thing, arcing in and shrinking into Mochi's mouth
                    Image(systemName: event.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(color)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.75)))
                        .overlay(Circle().stroke(color.opacity(0.6), lineWidth: 1))
                        .scaleEffect(1 - 0.8 * fly)
                        .opacity(fly < 1 ? 1 : 0)
                        .position(x: cx + (1 - fly) * 54,
                                  y: cy + (1 - fly) * 40 - sin(fly * .pi) * 22)
                    // Happy ring + "+1"
                    Circle()
                        .stroke(color.opacity(Double(1 - pop) * 0.8), lineWidth: 1.5)
                        .frame(width: d * (0.8 + pop * 0.9), height: d * (0.8 + pop * 0.9))
                        .position(x: cx, y: cy)
                        .opacity(pop > 0 ? 1 : 0)
                    Text("+1")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(color)
                        .shadow(color: .black, radius: 2)
                        .opacity(pop > 0 ? Double(1 - max(0, pop - 0.6) / 0.4) : 0)
                        .scaleEffect(0.6 + min(1, pop * 3) * 0.4)
                        .position(x: cx + d * 0.55, y: cy - d * 0.45 - pop * 10)
                }
            }
            .frame(width: islandW, height: islandH, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .onChangeCompat(of: state.catchEvent) { _, new in
            guard let new else { return }
            start = Date()
            event = new
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
                if event == new { event = nil }
            }
        }
    }
}
