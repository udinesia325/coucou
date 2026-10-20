import SwiftUI
import AppKit

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    /// When set, overrides island-based eye-tracking (used by desktop Mochi).
    /// CGPoint in the same coord space as state.mousePosition (DesktopSpace, y-down).
    var lookOriginOverride: CGPoint? = nil
    /// Not drawn while true (e.g. the notch copy while Mochi is on the desktop).
    var paused: Bool = false

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()
    @State private var props = MochiPropState()

    var body: some View {
        let engine = engine, props = props
        // fork: 30 fps, half the redraws of display rate (old Intel Macs lag at 60).
        MochiHost {
        TimelineView(.animation(minimumInterval: MochiFrameClock.interval(fps: 30),
                                paused: state.mode == .hidden || paused)) { timeline in
            // The Canvas must capture the frame's date: a closure that doesn't change from
            // one tick to the next is not redrawn, and Mochi froze.
            let frame = timeline.date
            Canvas { context, size in
                _ = frame
                let look = lookXY(state: state)
                engine.lookX = look.x
                engine.lookY = look.y
                engine.particleOverhang = particleOverhang
                // How the Mac feels (MochiMood.swift).
                engine.moodTarget = MachineVitals.shared.mood
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
                    let hex = state.planDetailIsCodex
                        ? CodexPlanGauge.color(state.codexPlanUsage)
                        : ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) })
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
                // Home with the Spotify pill playing: same headphones groove as the music tab.
                let homeSpotify = spotifyMochi && state.mode == .expanded && state.view == .overview
                #if !APPSTORE
                let mediaPlaying = homeSpotify || (state.mode == .expanded && state.view == .spotify
                    && (state.spotifyPlaying || NowPlaying.shared.isPlaying))
                #else
                let mediaPlaying = false
                #endif
                // Tab props (headphones, trader visor…) on the island's own Mochi only.
                let prop: MochiProp = lookOriginOverride == nil && state.mode == .expanded
                    ? (homeSpotify ? .headphones : MochiProp.forView(state.view)) : .none
                let isWardrobe = state.mode == .expanded && state.view == .wardrobe
                let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
                let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
                engine.setOutfit(prop != .none ? prop.outfit : (showOutfit ? state.resolvedOutfit : .none),
                                 animated: state.view != .wardrobe)

                #if !APPSTORE
                if state.view == .listening {
                    // Expanded listening view only (no longer used by voice, kept for the
                    // view itself). Smoothed so the eyes do not follow every mic frame.
                    let target = CGFloat(VoiceEngine.shared.micLevel)
                    engine.listeningLevel += (target - engine.listeningLevel) * 0.12
                    engine.listeningHasWords = !VoiceEngine.shared.commandTranscript.isEmpty
                } else if state.voiceActive && state.mode == .compact {
                    // Compact voice: feed mic level for the listening sub-state eye pulse.
                    let target = CGFloat(VoiceEngine.shared.micLevel)
                    engine.listeningLevel += (target - engine.listeningLevel) * 0.12
                }
                // Propagate voice sub-state every frame so BotEngine gets transitions promptly.
                if state.voiceActive { engine.voiceSubState = state.voiceSubState }
                else if engine.voiceSubState != .none { engine.voiceSubState = .none }
                #endif

                MochiFrameClock.advance(engine)
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
                let now = frame.timeIntervalSinceReferenceDate
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
        #if !APPSTORE
        .onChangeCompat(of: state.voiceActive) { _, on in
            if on { engine.enterVoiceCompact() } else { engine.exitVoiceCompact() }
        }
        #endif
        .onChangeCompat(of: state.view) { oldView, newView in
            // Morph up when upload view is active
            if state.mode == .expanded && newView == .upload {
                engine.anim("morph", keys: [TweenKey(target: 1, duration: 550, ease: Ease.inOut)])
            } else if newView != .upload && newView != .uploading && engine.morph > 0.01 {
                // Any other view (not mid-gulp): morph back
                engine.anim("morph", keys: [TweenKey(target: 0, duration: 550, ease: Ease.inOut)])
            }
            #if !APPSTORE
            if newView == .listening {
                engine.enterListening()
            } else if oldView == .listening {
                engine.exitListening(hadCommand: !VoiceEngine.shared.commandTranscript.isEmpty)
            }
            #endif
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

    /// Where Mochi looks (the pointer), both axes at once: the island geometry and the
    /// screen are looked up once per frame instead of twice each.
    private func lookXY(state: AppState) -> (x: CGFloat, y: CGFloat) {
        if let origin = lookOriginOverride {
            return (tanh((state.mousePosition.x - origin.x) / 260),
                    -tanh((state.mousePosition.y - origin.y) / 200))
        }
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let screen = IslandWindowController.islandScreen().frame
        let desktopTop = IslandWindowController.desktopTop
        // The pointer read now, not from the island poll (which slows down far from it).
        let mouse = DesktopSpace.topDown(NSEvent.mouseLocation, desktopTop: desktopTop)
        func botPoint(islandH: CGFloat) -> CGPoint {
            let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                    islandW: islandW, islandH: islandH,
                                                    uploadProgress: state.uploadProgress)
            return DesktopSpace.topDown(CGPoint(x: screen.midX - islandW / 2 + botCx,
                                                y: screen.maxY - botCy),
                                        desktopTop: desktopTop)
        }
        let botX = botPoint(islandH: islandH)
        // The chat view grows with the conversation: vertical look uses its real height.
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40)
            : islandH
        let botY = actualH == islandH ? botX : botPoint(islandH: actualH)
        return (tanh((mouse.x - botX.x) / 260),
                -tanh((mouse.y - botY.y) / 200))
    }
}

/// Mini bot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    var isDancing: Bool = false
    @StateObject private var engine: BotEngine

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

    @Environment(\.islandViewActive) private var viewActive


    var body: some View {
        let engine = engine, isDancing = isDancing
        // fork: 30 fps, in its own hosting view. Paused in island views that are not shown.
        MochiHost {
        TimelineView(.animation(minimumInterval: MochiFrameClock.interval(fps: 30), paused: !viewActive)) { timeline in
            let frame = timeline.date   // see BotCanvasView: redraw on every tick
            Canvas { context, size in
                _ = frame
                engine.setDancing(isDancing)
                MochiFrameClock.advance(engine)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                engine.draw(context: ctx, size: size)
            }
        }
        }
        .onChangeCompat(of: task.state) { _, newState in
            engine.setState(newState)
        }
        // The colour is set once, when the engine is made: a colour picked in
        // Settings has to reach a mini Mochi that is already on screen.
        .onChangeCompat(of: task.color) { _, newColor in
            engine.bodyColor = cgColorFromHex(newColor)
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

// MARK: - Frame clock

/// Mochi's engine has always moved one `update(dt: 0.05)` per display frame (its look,
/// colour, springs and particles are tuned to that). Drawing slower than the display must
/// not slow Mochi down: each drawn frame runs the steps of the display frames it skipped.
@MainActor
enum MochiFrameClock {
    /// The island screen's refresh rate, looked up at most every 2 s.
    private static var fpsCache: (value: Double, at: CFTimeInterval) = (60, -10)
    static var displayFPS: Double {
        let now = CACurrentMediaTime()
        if now - fpsCache.at > 2 {
            let fps = IslandWindowController.islandScreen().maximumFramesPerSecond
            fpsCache = (Double(min(120, max(30, fps))), now)
        }
        return fpsCache.value
    }

    /// minimumInterval for a target rate, 10 % short: display frames come every 16.6 ms
    /// with jitter, and an interval of exactly 1/60 s skipped every other one (30 fps on a
    /// 60 Hz screen). 60 on a 60 Hz screen draws every frame; on ProMotion, one in two.
    static func interval(fps: Double) -> TimeInterval { 0.9 / fps }

    /// One engine step per drawn frame, exactly as before the frame clock (9 October): a
    /// perfectly regular rhythm. The step-debt version measured the time between renders,
    /// and its jitter made frames with 0 steps (Mochi froze) and frames with 2 or more
    /// (Mochi jumped), several times a second: the stutter when the island opens and when
    /// Mochi follows the pointer. Mochi draws at the display rate, so one step per frame
    /// is one step per display frame, which is what his motion is tuned to.
    static func advance(_ engine: BotEngine) {
        engine.update(dt: 0.05)
    }
}
