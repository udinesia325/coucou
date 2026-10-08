import AVFoundation
import AppKit

/// Preloaded WAV players with near-zero latency.
/// Volume default 0.12 (matches prototype: gain ×6 then vol=0.12).
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    var enabled: Bool = true
    var volume: Float = 0.12 {
        didSet {
            let all = Array(players.values), v = volume
            queue.async { all.forEach { $0.players.forEach { $0.volume = v } } }
        }
    }

    /// AVAudioPlayer isn't Sendable; every player is only touched on `queue` after preload.
    private struct Pool: @unchecked Sendable { let players: [AVAudioPlayer] }

    // Pool of 3 players per sound to allow overlapping playback
    private var players: [String: Pool] = [:]
    /// `play()` blocks ~150–200 ms while the audio device wakes up (measured on an Intel Mac):
    /// on the main thread that froze the island right as it opened.
    private let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.sound", qos: .userInteractive)

    private init() {
        preload()
    }

    private func preload() {
        let names = ["peek","open","close","hover","blip","slap","annoyed","dizzy","greet",
                     "work","finish","error","approval","question","approve","gulp","tick",
                     "send","love","pop","proud","wink","yawn","attach","think","search",
                     "rate","sleep","greeting"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") else { continue }
            var pool: [AVAudioPlayer] = []
            for _ in 0..<3 {
                if let p = try? AVAudioPlayer(contentsOf: url) {
                    p.volume = volume
                    p.prepareToPlay()
                    pool.append(p)
                }
            }
            if !pool.isEmpty { players[name] = Pool(players: pool) }
        }
    }

    /// Fade out all currently-playing instances of `name` over `duration` seconds,
    /// then stop and reset them so they can be reused.
    func fadeOut(_ name: String, duration: TimeInterval) {
        guard let pool = players[name] else { return }
        let restore = volume, queue = queue
        queue.async {
            let fading = Pool(players: pool.players.filter { $0.isPlaying })
            fading.players.forEach { $0.setVolume(0, fadeDuration: duration) }
            queue.asyncAfter(deadline: .now() + duration) {
                for player in fading.players {
                    player.stop()
                    player.currentTime = 0
                    player.volume = restore
                }
            }
        }
    }

    func play(_ name: String) {
        guard enabled && AppState.shared.soundEnabled else { return }
        guard let pool = players[name] else { return }
        let volume = volume
        queue.async {
            // Find a player that is not currently playing
            let player = pool.players.first { !$0.isPlaying } ?? pool.players[0]
            player.currentTime = 0
            player.volume = volume
            player.play()
        }
    }
}
