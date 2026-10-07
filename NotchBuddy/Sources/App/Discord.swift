#if !APPSTORE
import AppKit
import Foundation
import SwiftUI

// MARK: - Discord voice controller (local RPC over the discord-ipc socket)

/// Shows the voice channel you're in and toggles mute / deafen through Discord's local RPC.
/// Needs the user's own Discord application (Client ID + Secret, kept in the Keychain):
/// voice control is an RPC scope Discord only grants to an app's owner.
@MainActor
final class DiscordController: ObservableObject {
    static let shared = DiscordController()
    nonisolated static let bundleIds: Set<String> = ["com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]
    nonisolated static let redirectURI = "http://localhost"
    private static let scopes = ["rpc", "rpc.voice.read", "rpc.voice.write"]

    enum Status: Equatable {
        case notConfigured, closed, connecting, authorizing, connected
        case failed(String)
    }

    @Published private(set) var status: Status = .notConfigured
    /// Voice channel name; nil when not in a voice channel.
    @Published private(set) var channel: String?
    @Published private(set) var muted = false
    @Published private(set) var deafened = false

    private var ipc: DiscordIPC?
    private var observers: [Any] = []

    var clientId: String? { KeychainStore.shared.get("discord-client-id") }
    private var clientSecret: String? { KeychainStore.shared.get("discord-client-secret") }

    private init() {
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard let id, DiscordController.bundleIds.contains(id) else { return }
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                Task { @MainActor [weak self] in
                    if launched {
                        try? await Task.sleep(nanoseconds: 6_000_000_000)   // RPC server starts after the window
                        self?.connect()
                    } else {
                        self?.disconnect(.closed)
                    }
                }
            })
        }
        connect()
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { Self.bundleIds.contains($0.bundleIdentifier ?? "") }
    }

    // MARK: Connection

    func connect() {
        guard ipc == nil else { return }
        guard let clientId, !clientId.isEmpty, clientSecret?.isEmpty == false else { status = .notConfigured; return }
        guard isRunning else { status = .closed; return }
        guard let ipc = DiscordIPC.connect() else { status = .failed("Can't reach Discord. Is it fully started?"); return }
        self.ipc = ipc
        status = .connecting
        // Frames from a socket we already replaced (reconnect) are ignored.
        let token = ObjectIdentifier(ipc)
        ipc.onFrame = { [weak self] op, data in
            Task { @MainActor [weak self] in
                guard let self, let current = self.ipc, ObjectIdentifier(current) == token else { return }
                self.handle(op: op, data: data)
            }
        }
        ipc.onClose = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let current = self.ipc, ObjectIdentifier(current) == token else { return }
                self.disconnect(.closed)
            }
        }
        ipc.start()
        ipc.send(op: 0, ["v": 1, "client_id": clientId])
    }

    /// Settings saved new credentials: forget tokens tied to the old app and start over.
    func reconnect(resetTokens: Bool) {
        if resetTokens {
            KeychainStore.shared.remove("discord-access-token")
            KeychainStore.shared.remove("discord-refresh-token")
        }
        disconnect(.notConfigured)
        connect()
    }

    private func disconnect(_ newStatus: Status) {
        ipc?.close()
        ipc = nil
        channel = nil
        status = newStatus
    }

    private func command(_ cmd: String, args: [String: Any] = [:], evt: String? = nil) {
        var payload: [String: Any] = ["cmd": cmd, "args": args, "nonce": UUID().uuidString]
        if let evt { payload["evt"] = evt }
        ipc?.send(op: 1, payload)
    }

    private func handle(op: UInt32, data: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if op == 2 {   // CLOSE
            disconnect(.failed((msg["message"] as? String) ?? "Discord closed the connection."))
            return
        }
        let cmd = msg["cmd"] as? String
        let evt = msg["evt"] as? String
        let body = msg["data"] as? [String: Any]

        if evt == "ERROR" {
            let message = body?["message"] as? String ?? "Discord error"
            if cmd == "AUTHENTICATE" {
                Task { await refreshOrAuthorize() }
            } else if cmd == "AUTHORIZE" {
                disconnect(.failed("Authorization cancelled: \(message)"))
            } else {
                status = .failed(message)
            }
            return
        }

        switch (cmd, evt) {
        case ("DISPATCH", "READY"):
            if let token = KeychainStore.shared.get("discord-access-token") {
                command("AUTHENTICATE", args: ["access_token": token])
            } else {
                authorize()
            }
        case ("AUTHORIZE", _):
            guard let code = body?["code"] as? String else { return }
            Task { await exchange(["grant_type": "authorization_code", "code": code]) }
        case ("AUTHENTICATE", _):
            status = .connected
            command("SUBSCRIBE", evt: "VOICE_SETTINGS_UPDATE")
            command("SUBSCRIBE", evt: "VOICE_CHANNEL_SELECT")
            command("GET_VOICE_SETTINGS")
            command("GET_SELECTED_VOICE_CHANNEL")
        case ("GET_VOICE_SETTINGS", _), ("SET_VOICE_SETTINGS", _), ("DISPATCH", "VOICE_SETTINGS_UPDATE"):
            if let m = body?["mute"] as? Bool { muted = m }
            if let d = body?["deaf"] as? Bool { deafened = d }
        case ("GET_SELECTED_VOICE_CHANNEL", _):
            channel = body?["name"] as? String
        case ("DISPATCH", "VOICE_CHANNEL_SELECT"):
            if body?["channel_id"] is String { command("GET_SELECTED_VOICE_CHANNEL") } else { channel = nil }
        default:
            break
        }
    }

    // MARK: OAuth

    private func authorize() {
        guard let clientId else { return }
        status = .authorizing   // Discord shows its own "Authorize" popup
        command("AUTHORIZE", args: ["client_id": clientId, "scopes": Self.scopes])
    }

    private func refreshOrAuthorize() async {
        if let refresh = KeychainStore.shared.get("discord-refresh-token"),
           await exchange(["grant_type": "refresh_token", "refresh_token": refresh]) {
            return
        }
        authorize()
    }

    /// Code or refresh token → access token, then AUTHENTICATE. Returns false on failure.
    @discardableResult
    private func exchange(_ grant: [String: String]) async -> Bool {
        guard let clientId, let clientSecret else { return false }
        var form = grant
        form["client_id"] = clientId
        form["client_secret"] = clientSecret
        form["redirect_uri"] = Self.redirectURI
        guard let tokens = await Self.postToken(form) else {
            status = .failed("Discord refused the token. Check the Client Secret and the http://localhost redirect.")
            return false
        }
        KeychainStore.shared.set("discord-access-token", value: tokens.access)
        if let r = tokens.refresh { KeychainStore.shared.set("discord-refresh-token", value: r) }
        command("AUTHENTICATE", args: ["access_token": tokens.access])
        return true
    }

    private nonisolated static func postToken(_ form: [String: String]) async -> (access: String, refresh: String?)? {
        var request = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { return nil }
        return (access, json["refresh_token"] as? String)
    }

    // MARK: Controls

    func toggleMute() {
        muted.toggle()   // optimistic; Discord answers with the real state
        command("SET_VOICE_SETTINGS", args: ["mute": muted])
    }

    func toggleDeafen() {
        deafened.toggle()
        command("SET_VOICE_SETTINGS", args: ["deaf": deafened])
    }

    func openDiscord() {
        for id in Self.bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        if let web = URL(string: "https://discord.com/app") { NSWorkspace.shared.open(web) }
    }

    var statusLabel: String {
        switch status {
        case .notConfigured: return "Add your Discord app in Settings"
        case .closed:        return "Discord isn't running"
        case .connecting:    return "Connecting…"
        case .authorizing:   return "Click Authorize in Discord"
        case .failed(let m): return m
        case .connected:
            guard let channel else { return "Not in a voice channel" }
            return "In voice · \(channel)"
        }
    }
}

// MARK: - IPC socket ($TMPDIR/discord-ipc-N, frames: op UInt32 LE, length UInt32 LE, JSON)

final class DiscordIPC: @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "fr.louisraille.coucou.discord.read")
    private let writeQueue = DispatchQueue(label: "fr.louisraille.coucou.discord.write")
    // Set once before start(), read only on readQueue afterwards.
    var onFrame: (@Sendable (UInt32, Data) -> Void)?
    var onClose: (@Sendable () -> Void)?

    private init(fd: Int32) { self.fd = fd }

    static func connect() -> DiscordIPC? {
        let tmp = NSTemporaryDirectory()
        for i in 0..<10 {
            let path = (tmp as NSString).appendingPathComponent("discord-ipc-\(i)")
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); continue }
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if ok == 0 { return DiscordIPC(fd: fd) }
            Darwin.close(fd)
        }
        return nil
    }

    func start() {
        readQueue.async { [self] in
            while let header = readExactly(8) {
                let op = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
                let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
                guard length < 1 << 20, let body = readExactly(Int(length)) else { break }
                onFrame?(op, body)
            }
            onClose?()
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return data
    }

    func send(op: UInt32, _ payload: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(json)
        let bytes = frame
        writeQueue.async { [fd] in
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
        }
    }

    func close() {
        shutdown(fd, SHUT_RDWR)   // wakes the read loop; it then reports onClose
        writeQueue.async { [fd] in Darwin.close(fd) }
    }
}

// MARK: - Small controls used by the Spotify / Discord pill cards

struct PillIconButton: View {
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(hovered ? Color(hex: "#F5F6F8") : Color(hex: "#C5C8CD"))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Capsule toggle: red when "on" (muted / deafened), neutral otherwise.
struct PillToggleButton: View {
    let on: Bool
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundColor(on ? Color(hex: "#F4505E") : Color(hex: "#C5C8CD"))
            .background(Capsule().fill(on ? Color(hex: "#F4505E").opacity(0.15) : Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}
#endif
