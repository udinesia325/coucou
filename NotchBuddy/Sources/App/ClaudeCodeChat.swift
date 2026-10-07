#if !APPSTORE
import Foundation
import SwiftUI

// MARK: - Claude Code chat

/// Chat through the user's own `claude` CLI (their Claude login, no API key).
/// Each message runs `claude -p … --output-format stream-json`; follow-ups use `--resume`,
/// so the conversation is a real Claude Code session that also shows up in the terminal.
@MainActor
final class ClaudeCodeChat: ObservableObject {
    static let shared = ClaudeCodeChat()

    struct Session: Identifiable, Equatable, Sendable {
        let id: String          // session UUID (file name)
        let title: String
        let project: String
        let cwd: String?
        let date: Date
        let file: URL
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var loadingSessions = false
    /// Session the next message continues; nil starts a new one.
    @Published private(set) var sessionId: String?
    @Published private(set) var sessionTitle: String?
    private var sessionCwd: String?
    private var running: Process?

    nonisolated static let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    // MARK: Binary

    /// Usual install locations; the login-shell lookup below covers nvm, volta, bun and the rest.
    nonisolated static func knownBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [UserDefaults.standard.string(forKey: "claudeCodeBinary"),
                          "\(home)/.claude/local/claude", "\(home)/.local/bin/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude", "\(home)/.volta/bin/claude"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func findBinary() async -> String? {
        if let known = knownBinary() { return known }
        // GUI apps don't get the shell PATH: ask an interactive login zsh once, then cache it.
        let found: String? = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-ilc", "command -v claude"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: nil); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let path = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline).last.map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
                cont.resume(returning: path.flatMap { $0.hasPrefix("/") ? $0 : nil })
            }
        }
        if let found, FileManager.default.isExecutableFile(atPath: found) {
            UserDefaults.standard.set(found, forKey: "claudeCodeBinary")
            return found
        }
        return nil
    }

    // MARK: Sessions

    func newSession() {
        running?.terminate()
        sessionId = nil
        sessionTitle = nil
        sessionCwd = nil
    }

    func reloadSessions() {
        guard !loadingSessions else { return }
        loadingSessions = true
        Task {
            let list = await Task.detached { Self.listSessions() }.value
            sessions = list
            loadingSessions = false
        }
    }

    /// Continue an existing session: its history fills the chat, the next message resumes it.
    func open(_ session: Session, state: AppState) {
        newSession()
        sessionId = session.id
        sessionTitle = session.title
        sessionCwd = session.cwd
        Task {
            let history = await Task.detached { Self.loadHistory(session.file) }.value
            state.chatHistory = history
        }
    }

    // ponytail: 30 newest sessions, title from the first 256 KB of each file.
    nonisolated static func listSessions() -> [Session] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date)] = []
        for dir in dirs {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in items where f.pathExtension == "jsonl" && !f.lastPathComponent.hasPrefix("agent-") {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((f, date))
            }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(30).compactMap { file, date in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            let head = String(decoding: handle.readData(ofLength: 256 * 1024), as: UTF8.self)
            var title: String?, summary: String?, cwd: String?
            for line in head.split(whereSeparator: \.isNewline) {
                guard let obj = json(line) else { continue }
                if cwd == nil { cwd = obj["cwd"] as? String }
                if summary == nil, obj["type"] as? String == "summary" { summary = obj["summary"] as? String }
                if title == nil, obj["type"] as? String == "user", obj["isMeta"] as? Bool != true {
                    title = userText(obj)
                }
                if title != nil && cwd != nil { break }
            }
            guard let name = summary ?? title else { return nil }
            let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? file.deletingLastPathComponent().lastPathComponent
            return Session(id: file.deletingPathExtension().lastPathComponent,
                           title: String(name.prefix(80)), project: project, cwd: cwd, date: date, file: file)
        }
    }

    /// User and assistant text from a session transcript (tool calls and meta lines skipped).
    nonisolated static func loadHistory(_ file: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        var messages: [ChatMessage] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let obj = json(line), obj["isMeta"] as? Bool != true, obj["isSidechain"] as? Bool != true else { continue }
            switch obj["type"] as? String {
            case "user":
                if let text = userText(obj) { messages.append(ChatMessage(role: .user, content: text)) }
            case "assistant":
                let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let last = messages.last, last.role == .assistant {
                    messages[messages.count - 1].content += "\n\n" + text
                } else {
                    messages.append(ChatMessage(role: .assistant, content: text))
                }
            default: continue
            }
        }
        return Array(messages.suffix(60))
    }

    private nonisolated static func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// Typed text of a user entry; nil for tool results, slash-command wrappers and reminders.
    private nonisolated static func userText(_ obj: [String: Any]) -> String? {
        let content = (obj["message"] as? [String: Any])?["content"]
        let text: String
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:") else { return nil }
        return trimmed
    }

    // MARK: Send

    func send(query: String, context: PromptContext?, state: AppState) async {
        guard let binary = await Self.findBinary() else {
            fail("Claude Code isn't installed (no `claude` command found). Install it with `npm i -g @anthropic-ai/claude-code`, run `claude` once to log in, then try again.", state: state)
            return
        }
        var prompt = query
        if sessionId == nil, let context {
            switch context {
            case .window(let app, let title, let url):
                prompt = "Context — App: \(app), Window: \(title)\(url.map { ", URL: \($0)" } ?? "")\n\n" + query
            case .file(let name, let fileURL):
                prompt = "Attached file: \(fileURL?.path ?? name)\n\n" + query
            }
        }
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        if let id = sessionId { args += ["--resume", id] }
        if state.claudeCodeModel != "default" { args += ["--model", state.claudeCodeModel] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = sessionCwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? home
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // node-based installs need their own bin dir on PATH (GUI apps get a bare PATH).
        var env = ProcessInfo.processInfo.environment
        let binDir = URL(fileURLWithPath: binary).deletingLastPathComponent().path
        env["PATH"] = "\(binDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            fail("Couldn't start Claude Code: \(error.localizedDescription)", state: state)
            return
        }
        running = process
        state.chatHistory.append(ChatMessage(role: .assistant, content: ""))
        let index = state.chatHistory.count - 1
        var reply = ""
        var resultError: String?

        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let id = obj["session_id"] as? String { sessionId = id }
                switch obj["type"] as? String {
                case "assistant":
                    let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    for block in blocks {
                        switch block["type"] as? String {
                        case "text":
                            if let t = block["text"] as? String, !t.isEmpty {
                                reply += (reply.isEmpty ? "" : "\n\n") + t
                                state.stateOverride = .thinking
                            }
                        case "tool_use":
                            state.stateOverride = .working   // Mochi works while Claude uses tools
                        default: break
                        }
                    }
                    if state.chatHistory.indices.contains(index) { state.chatHistory[index].content = reply }
                case "result":
                    if obj["is_error"] as? Bool == true { resultError = obj["result"] as? String ?? "Claude Code returned an error." }
                    if reply.isEmpty, let r = obj["result"] as? String { reply = r }
                default: break
                }
            }
        } catch {}
        process.waitUntilExit()
        running = nil

        if sessionTitle == nil { sessionTitle = String(query.prefix(80)) }
        if reply.isEmpty {
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if state.chatHistory.indices.contains(index) { state.chatHistory.remove(at: index) }
            fail(resultError ?? (stderr.isEmpty ? "Claude Code didn't answer." : String(stderr.suffix(400))), state: state)
            return
        }
        if state.chatHistory.indices.contains(index) { state.chatHistory[index].content = reply }
        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    private func fail(_ message: String, state: AppState) {
        state.stateOverride = .error
        state.noteMessage = message
        state.view = .note
    }
}

// MARK: - Sessions picker (inside the chat model popover)

struct ClaudeCodeSessionsView: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    @ObservedObject var chat = ClaudeCodeChat.shared

    private let accent = Color(hex: ChatProvider.claudeCode.accentHex)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(["default", "sonnet", "opus", "haiku"], id: \.self) { m in
                    Button { state.claudeCodeModel = m } label: {
                        Text(m.capitalized)
                            .font(.system(size: 11, weight: state.claudeCodeModel == m ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(state.claudeCodeModel == m ? accent.opacity(0.2) : Color.white.opacity(0.06)))
                            .foregroundColor(state.claudeCodeModel == m ? accent : Color(hex: "#C8CDD4"))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                chat.newSession()
                state.chatHistory = []
                isPresented = false
            } label: {
                Label("New session", systemImage: "plus.bubble")
                    .font(.system(size: 12, weight: chat.sessionId == nil ? .semibold : .regular))
                    .foregroundColor(chat.sessionId == nil ? accent : Color(hex: "#C8CDD4"))
            }
            .buttonStyle(.plain)

            Text("Recent sessions").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "#6B7079"))
            if chat.loadingSessions && chat.sessions.isEmpty {
                ProgressView().scaleEffect(0.6)
            } else if chat.sessions.isEmpty {
                Text("No Claude Code sessions yet.").font(.system(size: 11)).foregroundColor(Color(hex: "#8A8F98"))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(chat.sessions) { s in
                            Button {
                                chat.open(s, state: state)
                                isPresented = false
                                SoundEngine.shared.play("blip")
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.title).font(.system(size: 12)).lineLimit(1)
                                        .foregroundColor(chat.sessionId == s.id ? accent : Color(hex: "#C8CDD4"))
                                    Text("\(s.project) · \(Self.relative.localizedString(for: s.date, relativeTo: Date()))")
                                        .font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079")).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(chat.sessionId == s.id ? accent.opacity(0.1) : Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { chat.reloadSessions() }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
#endif
