#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - System Now Playing (browsers, Music, VLC, podcasts…)

/// What Control Center shows under "Now Playing" — YouTube in Chrome or Safari, Music, VLC,
/// podcasts — read through the private MediaRemote framework. GitHub build only (private API).
/// macOS 15.4+ refuses it to third-party apps: `info` then stays nil and the tab shows Spotify only.
@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    struct Info: Equatable {
        var title: String
        var artist: String
        var duration: Double      // seconds, 0 for live streams
        var elapsed: Double       // seconds at `timestamp`
        var rate: Double
        var timestamp: Date
    }

    @Published private(set) var info: Info?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var app: NSRunningApplication?

    var appName: String { app?.localizedName ?? "Media" }
    /// Spotify also reports itself here; the Spotify player handles it.
    var isSpotify: Bool { app?.bundleIdentifier == SpotifyController.bundleId }

    // MRMediaRemote C entry points, resolved once.
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias GetBool = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias GetPID = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool
    private typealias SetElapsed = @convention(c) (Double) -> Void

    private struct API {
        let getInfo: GetInfo
        let isPlaying: GetBool
        let pid: GetPID
        let send: SendCommand
        let setElapsed: SetElapsed
    }

    private static let api: API? = {
        let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url) else { return nil }
        func fn<T>(_ name: String, _: T.Type) -> T? {
            CFBundleGetFunctionPointerForName(bundle, name as CFString).map { unsafeBitCast($0, to: T.self) }
        }
        guard let getInfo = fn("MRMediaRemoteGetNowPlayingInfo", GetInfo.self),
              let isPlaying = fn("MRMediaRemoteGetNowPlayingApplicationIsPlaying", GetBool.self),
              let pid = fn("MRMediaRemoteGetNowPlayingApplicationPID", GetPID.self),
              let send = fn("MRMediaRemoteSendCommand", SendCommand.self),
              let setElapsed = fn("MRMediaRemoteSetElapsedTime", SetElapsed.self) else { return nil }
        return API(getInfo: getInfo, isPlaying: isPlaying, pid: pid, send: send, setElapsed: setElapsed)
    }()

    private init() {}

    /// Polls while the music tab is on screen (0 % CPU otherwise).
    func run() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    func refresh() {
        guard let api = Self.api else { return }
        // Callbacks arrive on the main queue.
        api.getInfo(.main) { [weak self] dict in
            MainActor.assumeIsolated { self?.apply(dict) }
        }
        api.isPlaying(.main) { [weak self] playing in
            MainActor.assumeIsolated { if self?.isPlaying != playing { self?.isPlaying = playing } }
        }
        api.pid(.main) { [weak self] pid in
            MainActor.assumeIsolated {
                guard let self, self.app?.processIdentifier != pid else { return }
                self.app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
            }
        }
    }

    private func apply(_ d: [String: Any]) {
        func number(_ key: String) -> Double? { (d["kMRMediaRemoteNowPlayingInfo" + key] as? NSNumber)?.doubleValue }
        guard let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
            info = nil
            artwork = nil
            return
        }
        let new = Info(title: title,
                       artist: d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
                       duration: number("Duration") ?? 0,
                       elapsed: number("ElapsedTime") ?? 0,
                       rate: number("PlaybackRate") ?? 0,
                       timestamp: d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date())
        // Artwork is decoded only when the track changes (or arrives late).
        if new.title != info?.title || artwork == nil,
           let data = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            artwork = NSImage(data: data)
        } else if new.title != info?.title {
            artwork = nil
        }
        if new != info { info = new }
    }

    func position(at date: Date = Date()) -> Double {
        guard let i = info else { return 0 }
        let rate = i.rate > 0 ? i.rate : (isPlaying ? 1 : 0)
        let p = i.elapsed + date.timeIntervalSince(i.timestamp) * rate
        return i.duration > 0 ? min(max(0, p), i.duration) : max(0, p)
    }

    // MRMediaRemoteCommand: 2 toggle play/pause, 4 next, 5 previous.
    func playPause() { send(2) }
    func next()      { send(4) }
    func previous()  { send(5) }

    func seek(to seconds: Double) {
        Self.api?.setElapsed(seconds)
        refreshSoon()
    }

    func openApp() { app?.activate(options: []) }

    private func send(_ command: Int32) {
        _ = Self.api?.send(command, nil)
        refreshSoon()
    }

    private func refreshSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.refresh()
        }
    }
}
#endif
