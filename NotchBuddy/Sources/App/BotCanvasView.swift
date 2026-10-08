import AppKit
import SwiftUI

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    /// When set, overrides island-based eye-tracking (used by desktop Mochi).
    /// CGPoint in the same coord space as state.mousePosition (y-down from screen top).
    var lookOriginOverride: CGPoint? = nil

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()
    @State private var props = MochiPropState()

    var body: some View {
        let engine = engine, props = props
        // 30 fps: half the redraws of display rate, same look (old Intel Macs lag at 60).
        MochiHost {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: state.mode == .hidden)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let dtRaw = min(0.05, now - engine.lastTime)
                    let dt = dtRaw
                    engine.lookX = lookX(state: state, size: size)
                    engine.lookY = lookY(state: state, size: size)
                    engine.particleOverhang = particleOverhang
                    // Widen slot when file is hovering over the mailbox (morph > 0.5)
                    // Open mouth (hover=0.20R) when file dragged over box; close when not
                    if engine.morph > 0.3 {
                        engine.slotHTarget = state.fileDragOver ? 0.20 : 0
                    } else {
                        engine.slotHTarget = 0
                        if engine.morph < 0.05 { engine.slotH = 0; engine.slotHVel = 0 }
                    }
                    // Integration pills have a fixed brand color → use it as bodyColor.
                    // Claude Code tasks use state-based gradient (working=blue, thinking=purple, etc.).
                    #if !APPSTORE
                    if state.showingPlanDetail {
                        let hex = ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) })
                        engine.bodyColor = cgColorFromHex(hex)
                    } else {
                        engine.bodyColor = (state.focusTask?.isIntegration == true)
                            ? cgColorFromHex(state.focusTask!.color)
                            : nil
                    }
                    #else
                    engine.bodyColor = (state.focusTask?.isIntegration == true)
                        ? cgColorFromHex(state.focusTask!.color)
                        : nil
                    #endif
                    // Home keeps the colour of the selected pill; every other tab shows the original white Mochi.
                    if state.mode == .expanded && state.view != .overview { engine.bodyColor = nil }
                    // Spotify playing: Mochi turns Spotify green (compact notch, Home) and dances.
                    let spotifyMochi = state.spotifyPlaying
                        && [BotState.idle, .working, .thinking, .searching, .finished].contains(state.effectiveState)
                        && (state.mode == .compact || (state.mode == .expanded
                            && (state.view == .spotify || (state.view == .overview && state.focusId == "integration_spotify"))))
                    if spotifyMochi && !(state.mode == .expanded && state.view == .spotify) {
                        engine.bodyColor = cgColorFromHex("#1DB954")
                    }

                    // Compute shouldDance per-frame (no observer lag)
                    let dancing: Bool = {
                        #if !APPSTORE
                        guard AppState.shared.musicPlaying else { return false }
                        guard AppState.shared.activeIntegrations.contains("integration_music") else { return false }
                        let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
                        guard allowed.contains(state.effectiveState) else { return false }
                        if state.mode == .compact { return true }
                        return state.mode == .expanded && state.view == .overview && state.focusId == "integration_music"
                        #else
                        return false
                        #endif
                    }()
                    // Any other media playing in the music tab (YouTube, Music…) makes Mochi dance too.
                    #if !APPSTORE
                    let mediaDance = state.mode == .expanded && state.view == .spotify
                        && NowPlaying.shared.isPlaying && !NowPlaying.shared.isSpotify
                    #else
                    let mediaDance = false
                    #endif
                    engine.setDancing(dancing || spotifyMochi || mediaDance)
                    // Anything playing in the music tab (Spotify or other media): headphones thump, hands pump.
                    #if !APPSTORE
                    let mediaPlaying = state.mode == .expanded && state.view == .spotify
                        && (state.spotifyPlaying || NowPlaying.shared.isPlaying)
                    #else
                    let mediaPlaying = false
                    #endif
                    // Tab props (headphones, trader visor…) on the island's own Mochi only.
                    let prop: MochiProp = lookOriginOverride == nil && state.mode == .expanded
                        ? MochiProp.forView(state.view) : .none
                    let isWardrobe = state.mode == .expanded && state.view == .wardrobe
                    let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
                    let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
                    engine.setOutfit(prop != .none ? prop.outfit : (showOutfit ? state.resolvedOutfit : .none),
                                     animated: state.view != .wardrobe)

                    engine.update(dt: dt)
                    var ctx = context
                    engine.applyDance(&ctx, size: size)
                    // Rigid-roll: when Mochi wears an outfit (presence > 0.05) and is rolling,
                    // rotate the entire body+accessories context around the body center so the
                    // whole character genuinely turns. Particles/badge (drawHandsAndExtras) are
                    // drawn outside the rotated context and do not spin.
                    if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
                        let center = engine.bodyCenter(size: size)
                        var rigidCtx = ctx
                        rigidCtx.translateBy(x: center.x, y: center.y)
                        rigidCtx.rotate(by: .radians(engine.roll))
                        rigidCtx.translateBy(x: -center.x, y: -center.y)
                        engine.drawHandsBehind(context: rigidCtx, size: size)
                        engine.drawOutfitBehind(context: rigidCtx, size: size)
                        engine.draw(context: rigidCtx, size: size)
                        engine.drawOutfitFront(context: rigidCtx, size: size)
                    } else {
                        engine.drawHandsBehind(context: ctx, size: size)
                        engine.drawOutfitBehind(context: ctx, size: size)
                        engine.draw(context: ctx, size: size)
                        engine.drawOutfitFront(context: ctx, size: size)
                    }
                    prop.draw(in: ctx, engine: engine, size: size, now: now,
                              presence: props.presence(of: prop, now: now),
                              accent: Color(hex: "#1DB954"),
                              groove: props.groove(playing: mediaPlaying, now: now))
                    engine.drawHandsAndExtras(context: ctx, size: size)
                }
            }
        }
        .onChangeCompat(of: state.effectiveState) { _, newState in
            engine.setState(newState)
        }
        .onChangeCompat(of: state.view) { _, newView in
            // Morph up when upload view is active
            if state.mode == .expanded && newView == .upload {
                engine.anim("morph", keys: [TweenKey(target: 1, duration: 550, ease: Ease.inOut)])
            } else if newView != .upload && newView != .uploading && engine.morph > 0.01 {
                // Any other view (not mid-gulp): morph back
                engine.anim("morph", keys: [TweenKey(target: 0, duration: 550, ease: Ease.inOut)])
            }
        }
        .onChangeCompat(of: state.mode) { _, newMode in
            // Hard-reset morph when island collapses
            if newMode != .expanded {
                engine.tweens.removeValue(forKey: "morph")
                engine.locks.remove("morph")
                engine.morph = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
            if let emote = notif.object as? BotEmote {
                engine.triggerEmote(emote)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
            engine.slap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
            engine.blink()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botSetTgEs)) { notif in
            if let v = notif.object as? CGFloat {
                engine.tgEs = v
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGulp)) { _ in
            engine.gulp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botMorphTo)) { notif in
            if let target = notif.object as? CGFloat {
                let dur: CGFloat = target > 0.5 ? 550 : 650
                engine.anim("morph", keys: [TweenKey(target: target, duration: dur, ease: Ease.inOut)])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            engine.greet()
        }
        .onAppear {
            engine.setState(state.effectiveState, force: true)
            let isWardrobe = state.mode == .expanded && state.view == .wardrobe
            let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
            let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
            engine.setOutfit(showOutfit ? state.resolvedOutfit : .none, animated: false)
        }
    }

    private func lookX(state: AppState, size: CGSize) -> CGFloat {
        if let origin = lookOriginOverride {
            return tanh((state.mousePosition.x - origin.x) / 260)
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let (botCx, _, _, _) = botPosition(mode: state.mode, view: state.view,
                                            islandW: islandW, islandH: islandH,
                                            uploadProgress: state.uploadProgress)
        // Island is centered on screen; bot is at botCx within island coords
        let botScreenX = screen.frame.midX - islandW / 2 + botCx
        return tanh((state.mousePosition.x - botScreenX) / 260)
    }

    private func lookY(state: AppState, size: CGSize) -> CGFloat {
        if let origin = lookOriginOverride {
            return -tanh((state.mousePosition.y - origin.y) / 200)
        }
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40)
            : islandH
        let (_, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                             islandW: islandW, islandH: actualH,
                                             uploadProgress: state.uploadProgress)
        // Island top = screen top → bot screen Y = botCy from island top
        return -tanh((state.mousePosition.y - botCy) / 200)
    }
}

/// Mini bot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    var isDancing: Bool = false
    @StateObject private var engine: BotEngine
    @Environment(\.islandViewActive) private var viewActive

    init(task: AgentTask, isDancing: Bool = false) {
        self.task = task
        self.isDancing = isDancing
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    var body: some View {
        let engine = engine, isDancing = isDancing
        MochiHost {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !viewActive)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let dt = min(0.05, now - engine.lastTime)
                    engine.setDancing(isDancing)
                    engine.update(dt: dt)
                    var ctx = context
                    engine.applyDance(&ctx, size: size)
                    engine.draw(context: ctx, size: size)
                }
            }
        }
        .onChangeCompat(of: task.state) { _, newState in
            engine.setState(newState)
        }
        .onAppear {
            engine.setState(task.state, force: true)
            if let emote = task.emote {
                engine.setPermanentEmote(emote)
            }
            // Direct eye override takes priority (e.g. .wide eyes for Research)
            if let eye = task.miniEye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
        }
    }
}

/// Runs a per-frame animation in its own NSHostingView. A TimelineView inside the island's
/// hosting view made every Mochi frame (30 fps, × each mini Mochi) update and lay out the whole
/// island window; here a frame only redraws this one character.
struct IsolatedAnimation: NSViewRepresentable {
    let content: AnyView

    init<V: View>(@ViewBuilder _ content: () -> V) {
        self.content = AnyView(content())
    }

    final class Container: NSView {
        let host: NSHostingView<AnyView>

        init(_ content: AnyView) {
            host = NSHostingView(rootView: content)
            super.init(frame: .zero)
            if #available(macOS 13.0, *) { host.sizingOptions = [] }
            addSubview(host)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            host.frame = bounds
        }

        // Purely visual: clicks reach the island underneath (pill buttons, the AppKit bot monitor).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Container { Container(content) }

    func updateNSView(_ view: Container, context: Context) { view.host.rootView = content }
}

/// Diagnostic switch for the "click on the island doesn't open it" bug:
/// `defaults write fr.louisraille.NotchBuddy isolatedMochi -bool NO` draws Mochi inside the
/// island's own hosting view again (as before IsolatedAnimation). Default: isolated.
struct MochiHost<Content: View>: View {
    private let content: Content
    private let isolated = UserDefaults.standard.object(forKey: "isolatedMochi") as? Bool ?? true

    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        if isolated { IsolatedAnimation { content } } else { content }
    }
}
