#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Spotify controller

/// Follows Spotify through its distributed notification, drives it with AppleScript
/// (never launches it), and fetches synced lyrics from lrclib.net. GitHub build only.
@MainActor
final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()
    nonisolated static let bundleId = "com.spotify.client"
    static let green = Color(hex: "#1DB954")

    enum Lyrics: Equatable { case none, loading, synced([LyricLine]), plain(String), notFound }

    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var album: String?
    @Published private(set) var artworkURL: URL?
    @Published private(set) var duration: Double = 0      // seconds
    @Published private(set) var isPlaying = false
    @Published private(set) var shuffling = false
    @Published private(set) var volume: Double = 50       // 0…100
    @Published private(set) var lyrics: Lyrics = .none
    @Published private(set) var automationDenied = false
    @Published private(set) var isRunning = false

    /// Lyrics come from lrclib.net (free, no account). Off = no lyrics request at all.
    @Published var lyricsEnabled: Bool = UserDefaults.standard.object(forKey: "spotifyLyricsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lyricsEnabled, forKey: "spotifyLyricsEnabled")
            lyricsEnabled ? fetchLyrics() : (lyrics = .none)
        }
    }
    /// Compact island shows one lyric line under the notch while Spotify plays.
    @Published var lyricInNotch: Bool = UserDefaults.standard.object(forKey: "spotifyLyricInNotch") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(lyricInNotch, forKey: "spotifyLyricInNotch")
            syncAppState()
        }
    }

    private var positionBase: Double = 0
    private var positionAt = Date()
    private var trackId: String?
    private var volumeBeforeMute: Double?
    private var lyricsTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private var observers: [Any] = []

    var isMuted: Bool { volumeBeforeMute != nil }
    var hasTrack: Bool { title != nil }

    private init() {
        isRunning = Self.running()
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] note in
            // Pull Sendable values out before hopping to the main actor.
            let info = note.userInfo
            let update = PlayerUpdate(
                state: info?["Player State"] as? String,
                name: info?["Name"] as? String,
                artist: info?["Artist"] as? String,
                album: info?["Album"] as? String,
                trackId: info?["Track ID"] as? String,
                durationMs: (info?["Duration"] as? NSNumber)?.doubleValue,
                position: (info?["Playback Position"] as? NSNumber)?.doubleValue)
            Task { @MainActor [weak self] in self?.apply(update) }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard id == SpotifyController.bundleId else { return }
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                Task { @MainActor [weak self] in
                    self?.isRunning = launched
                    if !launched { self?.clear() }
                }
            })
        }
    }

    private struct PlayerUpdate: Sendable {
        let state, name, artist, album, trackId: String?
        let durationMs, position: Double?
    }

    private func apply(_ u: PlayerUpdate) {
        isRunning = true
        guard u.state != "Stopped" else { clear(); return }
        let wasPlaying = isPlaying
        isPlaying = u.state == "Playing"
        if let n = u.name { title = n }
        if let a = u.artist { artist = a }
        if let a = u.album { album = a }
        if let d = u.durationMs, d > 0 { duration = d / 1000 }
        if let p = u.position { setPosition(p) } else { setPosition(position()) }
        if let id = u.trackId, id != trackId {
            trackId = id
            artworkURL = nil
            fetchLyrics()
        }
        refresh()
        syncAppState()
        if isPlaying && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func clear() {
        isPlaying = false
        title = nil; artist = nil; album = nil; artworkURL = nil; trackId = nil
        duration = 0; positionBase = 0
        lyricsTask?.cancel()
        lyrics = .none
        syncAppState()
    }

    private func syncAppState() {
        let state = AppState.shared
        if state.spotifyPlaying != isPlaying { state.spotifyPlaying = isPlaying }
        let row = isPlaying && lyricInNotch
        if state.spotifyLyricRow != row { state.spotifyLyricRow = row }
        // Lyrics drift: while playing, re-read Spotify's position every 10 s.
        if isPlaying, resyncTask == nil {
            resyncTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    self?.refresh()
                }
            }
        } else if !isPlaying {
            resyncTask?.cancel(); resyncTask = nil
        }
    }

    // MARK: Position

    private func setPosition(_ seconds: Double) {
        positionBase = seconds
        positionAt = Date()
    }

    func position(at date: Date = Date()) -> Double {
        let p = positionBase + (isPlaying ? date.timeIntervalSince(positionAt) : 0)
        return duration > 0 ? min(duration, p) : p
    }

    /// Current line for the compact notch: lyric, a note during breaks, or the track name.
    func compactLine(at date: Date) -> String {
        if case .synced(let lines) = lyrics, let i = LRC.index(in: lines, at: position(at: date) + 0.25) {
            return lines[i].text.isEmpty ? "♪ ♪ ♪" : lines[i].text
        }
        return [title, artist].compactMap { $0 }.joined(separator: " — ")
    }

    // MARK: AppleScript

    private static func running() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    /// Reads the full player state. Never launches Spotify.
    func refresh() {
        guard Self.running() else { isRunning = false; return }
        isRunning = true
        Task {
            let result = await Self.run("""
                tell application id "com.spotify.client"
                    set ps to player state as string
                    if ps is "stopped" then return {ps}
                    set t to current track
                    set au to ""
                    try
                        set au to artwork url of t
                    end try
                    return {ps, player position as string, shuffling as string, sound volume as string, au, ¬
                        duration of t as string, name of t, artist of t, album of t, id of t}
                end tell
                """)
            switch result {
            case .denied:
                automationDenied = true
            case .failed:
                break
            case .values(let v):
                automationDenied = false
                guard v.first != "stopped" else { clear(); return }
                guard v.count >= 10 else { return }
                let wasPlaying = isPlaying
                isPlaying = v[0] == "playing"
                if let p = Self.number(v[1]) { setPosition(p) }
                shuffling = v[2] == "true"
                if let vol = Self.number(v[3]) { volume = vol }
                artworkURL = URL(string: v[4])
                if let d = Self.number(v[5]), d > 0 { duration = d / 1000 }
                title = v[6]; artist = v[7]; album = v[8]
                if v[9] != trackId { trackId = v[9]; fetchLyrics() }
                syncAppState()
                if isPlaying && !wasPlaying {
                    NotificationCenter.default.post(name: .musicReveal, object: nil)
                }
            }
        }
    }

    /// AppleScript formats reals with the user's locale ("12,5" in many languages).
    private static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }

    private func command(_ body: String) {
        guard Self.running() else { return }
        Task {
            let result = await Self.run("tell application id \"com.spotify.client\" to \(body)")
            if case .denied = result {
                automationDenied = true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            refresh()
        }
    }

    func playPause() {
        isPlaying.toggle()                   // optimistic; refresh() corrects it
        setPosition(position())
        command("playpause")
    }
    func next()     { command("next track") }
    func previous() { command("previous track") }
    func toggleShuffle() {
        shuffling.toggle()
        command("set shuffling to \(shuffling)")
    }
    func setVolume(_ v: Double) {
        volume = v.rounded()
        volumeBeforeMute = nil
        command("set sound volume to \(Int(volume))")
    }
    func toggleMute() {
        if let restore = volumeBeforeMute {
            volumeBeforeMute = nil
            volume = restore
        } else {
            volumeBeforeMute = max(volume, 10)
            volume = 0
        }
        command("set sound volume to \(Int(volume))")
    }
    func seek(to seconds: Double) {
        setPosition(seconds)
        command("set player position to \(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), seconds))")
    }

    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let web = URL(string: "https://open.spotify.com") {
            NSWorkspace.shared.open(web)
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private enum ScriptResult: Sendable { case values([String]), denied, failed }
    private nonisolated static let scriptQueue = DispatchQueue(label: "fr.louisraille.coucou.spotify")

    private nonisolated static func run(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { cont in
            scriptQueue.async {
                guard let script = NSAppleScript(source: source) else { cont.resume(returning: .failed); return }
                var error: NSDictionary?
                let desc = script.executeAndReturnError(&error)
                if let error {
                    cont.resume(returning: (error[NSAppleScript.errorNumber] as? Int) == -1743 ? .denied : .failed)
                    return
                }
                var values: [String] = []
                if desc.numberOfItems > 0 {
                    for i in 1...desc.numberOfItems { values.append(desc.atIndex(i)?.stringValue ?? "") }
                } else {
                    values = [desc.stringValue ?? ""]
                }
                cont.resume(returning: .values(values))
            }
        }
    }

    // MARK: Lyrics (lrclib.net)

    private struct LyricsPayload: Decodable, Sendable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private func fetchLyrics() {
        lyricsTask?.cancel()
        guard lyricsEnabled, let title, let artist else { lyrics = .none; return }
        lyrics = .loading
        let albumName = album ?? "", seconds = Int(duration.rounded())
        lyricsTask = Task { [weak self] in
            var exact = URLComponents(string: "https://lrclib.net/api/get")!
            exact.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist),
                                .init(name: "album_name", value: albumName), .init(name: "duration", value: "\(seconds)")]
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]

            var payload: LyricsPayload? = await Self.get(exact.url!)
            if payload?.syncedLyrics == nil, let found: [LyricsPayload] = await Self.get(search.url!) {
                payload = found.first { $0.syncedLyrics != nil } ?? found.first ?? payload
            }
            guard !Task.isCancelled, let self else { return }
            if let synced = payload?.syncedLyrics.map(LRC.parse), !synced.isEmpty {
                self.lyrics = .synced(synced)
            } else if let plain = payload?.plainLyrics, !plain.isEmpty {
                self.lyrics = .plain(plain)
            } else {
                self.lyrics = .notFound
            }
        }
    }

    private nonisolated static func get<T: Decodable & Sendable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue("Coucou (https://github.com/louis-cfm/coucou)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Expanded Spotify view

struct SpotifyView: View {
    @ObservedObject var state: AppState
    @ObservedObject var spotify = SpotifyController.shared
    @ObservedObject var media = NowPlaying.shared
    @State private var draggingVolume: Double?

    private var active: Bool { state.mode == .expanded && state.view == .spotify }

    /// Spotify always wins while it plays. Otherwise whatever else plays (YouTube, Music, VLC…)
    /// takes the tab, and a paused Spotify comes back when nothing else does.
    private var showsMedia: Bool {
        guard media.info != nil, !media.isSpotify, !(spotify.hasTrack && spotify.isPlaying) else { return false }
        return media.isPlaying || !spotify.hasTrack
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: spotify.isPlaying ? .green : (showsMedia && media.isPlaying ? .soft : nil))
            Group {
                if showsMedia {
                    mediaPlayer
                } else if spotify.automationDenied {
                    message("Coucou needs permission to control Spotify.",
                            button: "Open Automation Settings") { spotify.openAutomationSettings() }
                } else if !spotify.hasTrack {
                    message(spotify.isRunning ? "Play something in Spotify." : "Spotify isn't running.",
                            button: "Open Spotify") { spotify.openSpotify() }
                } else {
                    player
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
        .task(id: active) {
            guard active else { return }
            spotify.refresh()
            await media.run()
        }
    }

    // MARK: Other media (Now Playing)

    private var mediaPlayer: some View {
        HStack(alignment: .top, spacing: 12) {
            mediaArtwork
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.info?.title ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(media.info.map { $0.artist.isEmpty ? media.appName : $0.artist } ?? "")
                        .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                }
                mediaProgress
                HStack(spacing: 18) {
                    control("backward.fill", size: 14) { media.previous() }
                    Button(action: { media.playPause() }) {
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.black)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    control("forward.fill", size: 14) { media.next() }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 200)
            mediaSource
        }
    }

    private var mediaArtwork: some View {
        ZStack {
            if let art = media.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.06)
                if let icon = media.app?.icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                } else {
                    Image(systemName: "play.rectangle.fill").font(.system(size: 30)).foregroundColor(Color(hex: "#C5C8CD"))
                }
            }
        }
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { media.openApp() }
    }

    private var mediaProgress: some View {
        TimelineView(.periodic(from: .now, by: active && media.isPlaying ? 0.5 : 3600)) { ctx in
            let pos = media.position(at: ctx.date)
            let duration = media.info?.duration ?? 0
            VStack(spacing: 2) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Color.white.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(duration > 0 ? pos / duration : 0))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                        guard duration > 0 else { return }
                        media.seek(to: max(0, min(1, g.location.x / geo.size.width)) * duration)
                    })
                }
                .frame(height: 4)
                HStack {
                    Text(Self.time(pos))
                    Spacer()
                    Text(duration > 0 ? Self.time(duration) : "Live")
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(Color(hex: "#6B7079"))
            }
        }
    }

    /// Where it plays, and a reminder that Spotify comes first.
    private var mediaSource: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Now Playing").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "#6B7079"))
            Button(action: { media.openApp() }) {
                HStack(spacing: 8) {
                    if let icon = media.app?.icon {
                        Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.appName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(media.isPlaying ? "Playing" : "Paused")
                            .font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "music.note").font(.system(size: 9)).foregroundColor(SpotifyController.green)
                Text(spotify.hasTrack ? "Spotify takes over when it plays." : "Spotify comes first when it plays.")
                    .font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func message(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note").font(.system(size: 22)).foregroundColor(SpotifyController.green)
            Text(text).font(.system(size: 12.5)).foregroundColor(Color(hex: "#C5C8CD"))
            Spacer()
            Button(button, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(SpotifyController.green.opacity(0.2)))
                .foregroundColor(SpotifyController.green)
        }
        .frame(maxHeight: .infinity)
    }

    private var player: some View {
        HStack(alignment: .top, spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(spotify.title ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(spotify.artist ?? "").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
                }
                progress
                controls
                volume
            }
            .frame(width: 200)
            lyricsColumn
        }
    }

    private var artwork: some View {
        AsyncImage(url: spotify.artworkURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                SpotifyController.green.opacity(0.15)
                Image(systemName: "music.note").font(.system(size: 26)).foregroundColor(SpotifyController.green)
            }
        }
        .frame(width: 112, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { spotify.openSpotify() }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: active && spotify.isPlaying ? 0.5 : 3600)) { ctx in
            let pos = spotify.position(at: ctx.date)
            VStack(spacing: 2) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Color.white.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(spotify.duration > 0 ? pos / spotify.duration : 0))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                        guard spotify.duration > 0 else { return }
                        spotify.seek(to: max(0, min(1, g.location.x / geo.size.width)) * spotify.duration)
                    })
                }
                .frame(height: 4)
                HStack {
                    Text(Self.time(pos))
                    Spacer()
                    Text(Self.time(spotify.duration))
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(Color(hex: "#6B7079"))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            control("shuffle", size: 12, on: spotify.shuffling) { spotify.toggleShuffle() }
            control("backward.fill", size: 14) { spotify.previous() }
            Button(action: { spotify.playPause() }) {
                Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.black)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
            control("forward.fill", size: 14) { spotify.next() }
        }
        .frame(maxWidth: .infinity)
    }

    private func control(_ icon: String, size: CGFloat, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundColor(on ? SpotifyController.green : Color(hex: "#C5C8CD"))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var volume: some View {
        HStack(spacing: 6) {
            Button(action: { spotify.toggleMute() }) {
                Image(systemName: spotify.isMuted || spotify.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundColor(spotify.isMuted ? Color(hex: "#F4505E") : Color(hex: "#8E939C"))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            Slider(value: Binding(get: { draggingVolume ?? spotify.volume },
                                  set: { draggingVolume = $0 }),
                   in: 0...100, onEditingChanged: { editing in
                if !editing, let v = draggingVolume {
                    spotify.setVolume(v)
                    draggingVolume = nil
                }
            })
            .controlSize(.mini)
            .tint(SpotifyController.green)
        }
    }

    @ViewBuilder private var lyricsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Lyrics").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "#6B7079"))
                Spacer()
                Menu {
                    Toggle("Fetch lyrics (lrclib.net)", isOn: $spotify.lyricsEnabled)
                    Toggle("Lyric line in the compact notch", isOn: $spotify.lyricInNotch)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundColor(Color(hex: "#8E939C"))
            }
            switch spotify.lyrics {
            case .synced(let lines):
                TimelineView(.periodic(from: .now, by: active && spotify.isPlaying ? 0.25 : 3600)) { ctx in
                    let i = LRC.index(in: lines, at: spotify.position(at: ctx.date) + 0.25)
                    VStack(alignment: .leading, spacing: 5) {
                        lyric(i.flatMap { $0 > 0 ? lines[$0 - 1].text : nil }, current: false)
                        lyric(i.map { lines[$0].text.isEmpty ? "♪" : lines[$0].text } ?? "♪", current: true)
                        lyric(lines.indices.contains((i ?? -1) + 1) ? lines[(i ?? -1) + 1].text : nil, current: false)
                    }
                    .animation(.easeInOut(duration: 0.25), value: i)
                }
            case .plain(let text):
                ScrollView(showsIndicators: false) {
                    Text(text).font(.system(size: 11)).foregroundColor(Color(hex: "#C5C8CD"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .loading:
                hint("Looking for lyrics…")
            case .notFound:
                hint("No lyrics found for this track.")
            case .none:
                hint(spotify.lyricsEnabled ? "" : "Lyrics are off.")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func lyric(_ text: String?, current: Bool) -> some View {
        Text(text ?? " ")
            .font(.system(size: current ? 13.5 : 11, weight: current ? .bold : .regular))
            .foregroundColor(current ? SpotifyController.green : Color(hex: "#6B7079"))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079"))
    }

    static func time(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Compact notch: one lyric line + music notes around Mochi

struct CompactSpotifyOverlay: View {
    @ObservedObject var spotify = SpotifyController.shared
    let islandW: CGFloat
    let islandH: CGFloat
    /// true: [Mochi][lyric][mini grid] on one line; false: lyric row under the notch.
    let inline: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !spotify.isPlaying)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                notes(t)
                HStack(spacing: 6) {
                    equalizer(t)
                    Text(spotify.compactLine(at: ctx.date))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(spotify.compactLine(at: ctx.date))
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .opacity))
                }
                .frame(width: inline ? islandW - 128 : islandW - 84,
                       height: inline ? islandH : compactLyricRowHeight, alignment: .center)
                .offset(x: 64, y: inline ? 0 : islandH - compactLyricRowHeight)
                .animation(.easeOut(duration: 0.3), value: spotify.compactLine(at: ctx.date))
            }
            .frame(width: islandW, height: islandH, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    /// Three green bars bouncing out of phase.
    private func equalizer(_ t: Double) -> some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(SpotifyController.green)
                    .frame(width: 2.5, height: 3 + 7 * CGFloat(abs(sin(t * (5 + Double(i) * 1.7) + Double(i)))))
            }
        }
        .frame(height: 11, alignment: .bottom)
    }

    /// Little ♪ ♫ that float up from Mochi and fade out.
    private func notes(_ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { i in
                let phase = (t / 2.2 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text(i == 1 ? "♫" : "♪")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(SpotifyController.green)
                    .opacity(sin(phase * .pi))
                    .offset(x: 52 + CGFloat(i * 6) + 3 * CGFloat(sin(t * 3 + Double(i))),
                            y: islandH * 0.75 - CGFloat(phase) * islandH * 0.7)
            }
        }
    }
}
#endif
