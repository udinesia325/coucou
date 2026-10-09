import AppKit
import SwiftUI

// MARK: - Developer tools tab: service ports, custom ports, toolchain versions, CLI shortcuts

/// What the user sets up in this tab. Saved to ~/.coucou/devtools.json so it survives reinstall.
struct DevToolsConfig: Codable, Equatable {
    struct Port: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var port: Int
    }
    struct Shortcut: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var command: String
    }
    var ports: [Port] = []
    var shortcuts: [Shortcut] = []
}

// Lenient decoding: a hand-edited file may leave out ids or a whole list.
extension DevToolsConfig {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ports = try c.decodeIfPresent([Port].self, forKey: .ports) ?? []
        shortcuts = try c.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? []
    }
}
extension DevToolsConfig.Port {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        port = try c.decode(Int.self, forKey: .port)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Port \(port)"
    }
}
extension DevToolsConfig.Shortcut {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        command = try c.decode(String.self, forKey: .command)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? command
    }
}

@MainActor
final class DevToolsStore: ObservableObject {
    static let shared = DevToolsStore()

    static let services: [(title: String, port: Int)] = [("MySQL", 3306), ("Redis", 6379), ("Apache", 80)]

    /// Active version as a new Terminal window sees it (nvm, asdf, brew… resolved by the login shell).
    static let tools: [(name: String, bin: String, cmd: String)] = [
        ("Node", "node", "node -v"),
        ("PHP", "php", "php -r 'echo PHP_VERSION;'"),
        ("Redis", "redis-server", "redis-server --version"),
        ("MySQL", "mysql", "mysql --version"),
        ("Apache", "httpd", "httpd -v"),
        ("Go", "go", "go version"),
        ("Python", "python3", "python3 --version"),
    ]

    struct Listener: Sendable { var pid: Int32; var command: String }
    struct ToolVersion: Sendable { var version: String?; var path: String? }
    enum RunState: Equatable { case running, done(String), failed(String) }

    @Published var config: DevToolsConfig { didSet { if config != oldValue { save() } } }
    @Published private(set) var openPorts: Set<Int> = []
    @Published private(set) var owners: [Int: Listener] = [:]
    @Published private(set) var scanned = false
    @Published private(set) var versions: [String: ToolVersion] = [:]
    @Published private(set) var loadingVersions = false
    @Published private(set) var runs: [UUID: RunState] = [:]
    @Published var notice: String?

    private var processes: [UUID: Process] = [:]

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".coucou/devtools.json")

    private init() {
        var loadError: String?
        if let data = try? Data(contentsOf: Self.fileURL) {
            do {
                config = try JSONDecoder().decode(DevToolsConfig.self, from: data)
            } catch {
                // Never overwrite a file we can't read: keep it aside for the user.
                let bad = Self.fileURL.appendingPathExtension("bad")
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: Self.fileURL, to: bad)
                config = DevToolsConfig()
                loadError = "~/.coucou/devtools.json couldn't be read (\(error.localizedDescription)). It was kept as devtools.json.bad."
            }
        } else {
            config = DevToolsConfig()
        }
        notice = loadError
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(config)
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: Self.fileURL, options: .atomic)
            // Commands may hold hosts or tokens: owner-only, like settings.json.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        } catch {
            notice = "Couldn't save ~/.coucou/devtools.json: \(error.localizedDescription)"
        }
    }

    // MARK: Config edits

    /// nil when added, otherwise why not.
    func addPort(title: String, port text: String) -> String? {
        guard let port = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            return "The port must be a number between 1 and 65535."
        }
        if Self.services.contains(where: { $0.port == port }) || config.ports.contains(where: { $0.port == port }) {
            return "Port \(port) is already in the list."
        }
        let t = title.trimmingCharacters(in: .whitespaces)
        config.ports.append(.init(title: t.isEmpty ? "Port \(port)" : t, port: port))
        Task { await refreshPorts() }
        return nil
    }

    func removePort(_ p: DevToolsConfig.Port) { config.ports.removeAll { $0.id == p.id } }

    func addShortcut(title: String, command: String) -> String? {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return "Type the command to run." }
        let t = title.trimmingCharacters(in: .whitespaces)
        config.shortcuts.append(.init(title: t.isEmpty ? c : t, command: c))
        return nil
    }

    func removeShortcut(_ s: DevToolsConfig.Shortcut) {
        stopRun(s.id)
        runs[s.id] = nil
        config.shortcuts.removeAll { $0.id == s.id }
    }

    // MARK: Ports

    /// Rescans every 4 s until the calling task is cancelled (the tab closes).
    func watch() async {
        if versions.isEmpty && !loadingVersions { Task { await refreshVersions() } }
        while !Task.isCancelled {
            await refreshPorts()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    func refreshPorts() async {
        let r = await Task.detached { Self.scanListeners() }.value
        openPorts = r.open
        owners = r.owners
        scanned = true
    }

    /// netstat sees every listening socket (any user); lsof names the owner, but only for our own processes.
    /// No test connections: MySQL blocks a host after too many half-open connects.
    nonisolated static func scanListeners() -> (open: Set<Int>, owners: [Int: Listener]) {
        var open = Set<Int>()
        for line in run("/usr/sbin/netstat", ["-an", "-p", "tcp"]).split(separator: "\n") where line.hasSuffix("LISTEN") {
            let cols = line.split(separator: " ")
            // Local address: "*.3306", "127.0.0.1.6379", "::1.5500"
            if cols.count > 3, let p = cols[3].split(separator: ".").last.flatMap({ Int($0) }) { open.insert(p) }
        }
        var owners: [Int: Listener] = [:]
        var pid: Int32 = 0, cmd = ""
        for line in run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]).split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value) ?? 0
            case "c": cmd = value
            case "n":
                // "*:3306", "[::1]:6379"
                if let p = value.split(separator: ":").last.flatMap({ Int($0) }) {
                    open.insert(p)
                    if owners[p] == nil { owners[p] = Listener(pid: pid, command: cmd) }
                }
            default: break
            }
        }
        return (open, owners)
    }

    /// Asks the process listening on `port` to quit (SIGTERM), then checks it really let go.
    func stop(port: Int) {
        guard let l = owners[port] else {
            notice = "Port \(port) belongs to the system or another user, so Coucou can't stop it without admin rights. "
                + (port == 80 ? "For the built-in Apache run in Terminal: sudo apachectl stop" :
                   "In Terminal: sudo lsof -nP -iTCP:\(port) -sTCP:LISTEN to find the PID, then sudo kill <PID>.")
            return
        }
        if kill(l.pid, SIGTERM) != 0 {
            let e = errno
            notice = e == EPERM
                ? "No permission to stop \(l.command) (PID \(l.pid)). Try in Terminal: sudo kill \(l.pid)"
                : "Couldn't stop \(l.command) (PID \(l.pid)): \(String(cString: strerror(e)))."
            return
        }
        notice = nil
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshPorts()
            guard openPorts.contains(port) else { return }
            if let again = owners[port], again.pid != l.pid {
                notice = "Port \(port) came back as \(again.command) (PID \(again.pid)): something restarts it, usually launchd / brew services. Try in Terminal: brew services stop <service>"
            } else {
                notice = "\(l.command) (PID \(l.pid)) is still listening on \(port): it may still be shutting down or ignore the request. Wait a moment, or force it in Terminal: kill -9 \(l.pid)"
            }
        }
    }

    // MARK: Versions

    func refreshVersions() async {
        loadingVersions = true
        let script = Self.tools.map {
            "echo \"@@\($0.name)@@$(command -v \($0.bin) 2>/dev/null)\"; command -v \($0.bin) >/dev/null 2>&1 && \($0.cmd) 2>&1 | head -2"
        }.joined(separator: "; ")
        let out = await Task.detached { Self.run(Self.userShell, ["-ilc", script], timeout: 20) }.value
        var found: [String: ToolVersion] = [:]
        var current: String?
        for line in out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("@@"), let end = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) {
                let name = String(line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound])
                let path = String(line[end.upperBound...])
                found[name] = ToolVersion(version: nil, path: path.isEmpty ? nil : path)
                current = name
            } else if let name = current, found[name]?.path != nil, found[name]?.version == nil,
                      let r = line.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
                found[name]?.version = String(line[r])
            }
        }
        versions = found
        loadingVersions = false
        if found.isEmpty {
            notice = "Couldn't read versions: your login shell (\(Self.userShell)) didn't answer within 20 s. Check ~/.zshrc for a command that waits for input."
        }
    }

    // MARK: Shortcuts

    func run(_ s: DevToolsConfig.Shortcut) {
        guard processes[s.id] == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.userShell)
        // Interactive login shell: the user's PATH, aliases and functions (db-staging…) all resolve.
        p.arguments = ["-ilc", s.command]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice   // a prompt fails fast instead of hanging forever
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let tail = OutputTail()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { tail.append(d) }
        }
        let id = s.id
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            let signaled = proc.terminationReason == .uncaughtSignal
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)   // let the last output arrive
                DevToolsStore.shared.finished(id, code: code, signaled: signaled, output: tail.text)
            }
        }
        do {
            try p.run()
            processes[id] = p
            runs[id] = .running
        } catch {
            runs[id] = .failed("Couldn't start \(Self.userShell): \(error.localizedDescription)")
        }
    }

    func stopRun(_ id: UUID) {
        guard let p = processes.removeValue(forKey: id) else { return }
        // Children (ssh tunnels, dev servers…) outlive the shell: stop them first.
        _ = Self.run("/usr/bin/pkill", ["-TERM", "-P", "\(p.processIdentifier)"])
        p.terminate()
        runs[id] = .done("Stopped")
    }

    func clearRun(_ id: UUID) { if processes[id] == nil { runs[id] = nil } }

    private func finished(_ id: UUID, code: Int32, signaled: Bool, output: String) {
        guard processes.removeValue(forKey: id) != nil else { return }   // stopped by the user
        let last = Self.lastLines(output)
        if code == 0 && !signaled {
            runs[id] = .done(last.isEmpty ? "Done" : last)
            SoundEngine.shared.play("approve")
        } else {
            runs[id] = .failed(Self.explain(code: code, signaled: signaled, output: last))
        }
    }

    nonisolated static func explain(code: Int32, signaled: Bool, output: String) -> String {
        let lower = output.lowercased()
        var why: String
        if signaled {
            why = "Killed by signal \(code)."
        } else {
            switch code {
            case 127: why = "Command not found. Check the spelling, and that it's on your PATH or defined as an alias or function in your shell config (~/.zshrc)."
            case 126: why = "Found but can't be executed. Make the script executable (chmod +x) or check its permissions."
            default:  why = "Failed with exit code \(code)."
            }
        }
        if lower.contains("permission denied") {
            why += " Permission denied: if it needs sudo, run it in Terminal (the notch can't type a password)."
        } else if lower.contains("password") || lower.contains("passphrase") {
            why += " It asked for a password, which the notch can't type. Use an SSH key or run it in Terminal."
        } else if ["could not resolve", "connection refused", "timed out", "network is unreachable"].contains(where: { lower.contains($0) }) {
            why += " Network problem: check your connection or VPN and the host name."
        }
        return output.isEmpty ? why : why + "\n" + output
    }

    nonisolated static func lastLines(_ s: String) -> String {
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String(lines.suffix(3).joined(separator: "\n").suffix(300))
    }

    // MARK: Process helpers

    nonisolated static var userShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { return String(cString: sh) }
        return "/bin/zsh"
    }

    /// Runs a tool and returns stdout (empty on failure). `timeout` kills it if it hangs.
    nonisolated static func run(_ path: String, _ args: [String], timeout: Double? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        if let timeout {
            let box = UncheckedBox(value: p)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if box.value.isRunning { box.value.terminate() } }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

private struct UncheckedBox<T>: @unchecked Sendable { let value: T }

/// Last few KB of a running command's output, written from the pipe's queue.
private final class OutputTail: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) {
        lock.withLock {
            data.append(d)
            if data.count > 8192 { data = data.suffix(4096) }
        }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

// MARK: - View

struct DevToolsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store = DevToolsStore.shared

    private enum Form { case port, shortcut }
    @State private var form: Form?
    @State private var title = ""
    @State private var value = ""
    @State private var formError: String?

    private var active: Bool { state.mode == .expanded && state.view == .devtools }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            HStack(alignment: .top, spacing: 10) {
                portsColumn.frame(width: 190)
                versionsColumn.frame(width: 120)
                shortcutsColumn
            }
            .padding(.leading, 84)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
        .overlay(alignment: .bottom) {
            if let n = store.notice {
                DevNoticeBar(text: n) { store.notice = nil }
                    .padding(.leading, 80).padding(.trailing, 10).padding(.bottom, 8)
            }
        }
        // 0 % CPU when hidden: scanning lives and dies with the tab.
        .task(id: active) {
            if active { await store.watch() }
        }
    }

    // MARK: Ports

    private var portsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            DevColumnHeader(title: "Ports") { addButton(.port) }
            if form == .port {
                addForm(titleHint: "Title (e.g. Live Server)", valueHint: "Port (e.g. 5500)")
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 1) {
                        ForEach(0..<DevToolsStore.services.count, id: \.self) { i in
                            DevPortRow(title: DevToolsStore.services[i].title, port: DevToolsStore.services[i].port,
                                       store: store, onRemove: nil)
                        }
                        ForEach(store.config.ports) { p in
                            DevPortRow(title: p.title, port: p.port, store: store, onRemove: { store.removePort(p) })
                        }
                    }
                }
            }
        }
    }

    // MARK: Versions

    private var versionsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            DevColumnHeader(title: "Versions") {
                Button { Task { await store.refreshVersions() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .rotationEffect(.degrees(store.loadingVersions ? 360 : 0))
                        .animation(store.loadingVersions ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: store.loadingVersions)
                }
                .buttonStyle(.plain)
                .disabled(store.loadingVersions)
                .help("Versions as a new Terminal window sees them (nvm, asdf, brew…)")
            }
            if store.versions.isEmpty {
                Text(store.loadingVersions ? "Reading…" : "—")
                    .font(.system(size: 10.5)).foregroundColor(Color(hex: "#6B7079"))
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(0..<DevToolsStore.tools.count, id: \.self) { i in
                        let t = DevToolsStore.tools[i]
                        if let v = store.versions[t.name] {
                            HStack(spacing: 4) {
                                Text(t.name).font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
                                Spacer(minLength: 2)
                                Text(v.path == nil ? "not found" : (v.version ?? "?"))
                                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                    .foregroundColor(v.path == nil ? Color(hex: "#6B7079") : Color(hex: "#E5E7EB"))
                                    .lineLimit(1)
                            }
                            .help(v.path ?? "Not on your PATH")
                        }
                    }
                }
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            DevColumnHeader(title: "Commands") { addButton(.shortcut) }
            if form == .shortcut {
                addForm(titleHint: "Title (e.g. DB staging)", valueHint: "Command (e.g. db-staging)")
            } else if store.config.shortcuts.isEmpty {
                Text("No commands yet. Add one with + and run it from here with a click.")
                    .font(.system(size: 10.5)).foregroundColor(Color(hex: "#6B7079"))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(store.config.shortcuts) { DevShortcutRow(shortcut: $0, store: store) }
                    }
                }
            }
        }
    }

    // MARK: Add form (ports and commands)

    private func addButton(_ f: Form) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                form = form == f ? nil : f
                title = ""; value = ""; formError = nil
            }
        } label: {
            Image(systemName: form == f ? "xmark" : "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(hex: "#8E939C"))
        }
        .buttonStyle(.plain)
    }

    private func addForm(titleHint: String, valueHint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DevField(hint: titleHint, text: $title, onSubmit: { submit() })
            DevField(hint: valueHint, text: $value, onSubmit: { submit() })
            HStack {
                if let formError {
                    Text(formError).font(.system(size: 9.5)).foregroundColor(Color(hex: "#F4505E")).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Add") { submit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#22D3EE"))
            }
        }
    }

    private func submit() {
        let err = form == .port
            ? store.addPort(title: title, port: value)
            : store.addShortcut(title: title, command: value)
        if let err {
            formError = err
        } else {
            withAnimation(.easeInOut(duration: 0.15)) { form = nil }
        }
    }
}

private struct DevColumnHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
            trailing
        }
    }
}

private struct DevField: View {
    let hint: String
    @Binding var text: String
    let onSubmit: () -> Void

    var body: some View {
        TextField(hint, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            .onSubmit { onSubmit() }
    }
}

private struct DevPortRow: View {
    let title: String
    let port: Int
    @ObservedObject var store: DevToolsStore
    let onRemove: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        let open = store.openPorts.contains(port)
        let owner = store.owners[port]
        HStack(spacing: 5) {
            Circle()
                .fill(!store.scanned ? Color(hex: "#4B5058") : open ? Color(hex: "#34D399") : Color(hex: "#F4505E").opacity(0.8))
                .frame(width: 6, height: 6)
            Text(title).font(.system(size: 11)).foregroundColor(Color(hex: "#E5E7EB")).lineLimit(1)
            Spacer(minLength: 2)
            Text(":\(port)").font(.system(size: 10, design: .monospaced)).foregroundColor(Color(hex: "#8E939C"))
            if open {
                TwoTapStopButton(help: "Stop what listens on \(port)") { store.stop(port: port) }
            }
            if let onRemove, hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .help("Remove from the list")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .help(!store.scanned ? "Checking…" : open
              ? (owner.map { "Open · \($0.command) (PID \($0.pid))" } ?? "Open · owned by the system or another user")
              : "Closed")
    }
}

private struct DevShortcutRow: View {
    let shortcut: DevToolsConfig.Shortcut
    @ObservedObject var store: DevToolsStore
    @State private var hovered = false

    var body: some View {
        let run = store.runs[shortcut.id]
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { store.run(shortcut) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal").font(.system(size: 9.5))
                        Text(shortcut.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundColor(Color(hex: "#E5E7EB"))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovered ? 0.1 : 0.06)))
                }
                .buttonStyle(.plain)
                .disabled(run == .running)
                .help(shortcut.command)
                if run == .running {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    Button("Stop") { store.stopRun(shortcut.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#F4505E"))
                }
                Spacer(minLength: 0)
                if hovered && run != .running {
                    Button { store.removeShortcut(shortcut) } label: {
                        Image(systemName: "trash").font(.system(size: 9)).foregroundColor(Color(hex: "#8E939C"))
                    }
                    .buttonStyle(.plain)
                    .help("Remove this command")
                }
            }
            switch run {
            case .done(let text)?:
                resultText(text, color: Color(hex: "#34D399"), icon: "checkmark.circle.fill")
            case .failed(let text)?:
                resultText(text, color: Color(hex: "#F4505E"), icon: "exclamationmark.triangle.fill")
            default:
                EmptyView()
            }
        }
        .onHover { hovered = $0 }
    }

    private func resultText(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(color)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(4)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { store.clearRun(shortcut.id) } label: {
                Image(systemName: "xmark").font(.system(size: 7)).foregroundColor(Color(hex: "#6B7079"))
            }
            .buttonStyle(.plain)
        }
        .help(text)
    }
}

/// Stop button that needs a second click within 3 s, so a stray click never kills anything.
struct TwoTapStopButton: View {
    var label = "Stop"
    let help: String
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed {
                armed = false
                action()
            } else {
                armed = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    armed = false
                }
            }
        } label: {
            Group {
                if armed {
                    Text("\(label)?").font(.system(size: 9.5, weight: .bold))
                } else {
                    Image(systemName: "stop.fill").font(.system(size: 7.5))
                }
            }
            .foregroundColor(armed ? .white : Color(hex: "#F4505E"))
            .padding(.horizontal, armed ? 6 : 4).padding(.vertical, 2)
            .background(Capsule().fill(armed ? Color(hex: "#F4505E") : Color(hex: "#F4505E").opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help(armed ? "Click again to confirm" : help)
    }
}

/// Error / hint strip at the bottom of a card.
struct DevNoticeBar: View {
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(Color(hex: "#F5A524"))
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#E5E7EB"))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#F4505E"))
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8)).foregroundColor(Color(hex: "#8E939C"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#24262B")))
        .help(text)
    }
}
