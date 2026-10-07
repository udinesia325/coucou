import AppKit
import SwiftUI

// MARK: - Shelf store (Dropzone-style drop bar: hold files, drag them out later)

/// Holds references to dropped files (no copies), in memory only.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [URL] = []
    /// A drag is hovering the island while it routes to the shelf.
    @Published var isTargeted = false
    /// Every file dragged onto the notch lands on the shelf instead of the upload flow.
    @Published var catchesDrops: Bool = UserDefaults.standard.object(forKey: "shelfCatchesDrops") as? Bool ?? true {
        didSet { UserDefaults.standard.set(catchesDrops, forKey: "shelfCatchesDrops") }
    }

    func add(_ urls: [URL]) {
        let new = urls.filter { !items.contains($0) }
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        MochiCatch.fire(icon: "tray.and.arrow.down.fill", color: "#34D399")
    }

    func remove(_ url: URL) { items.removeAll { $0 == url } }
    func clear() { items.removeAll() }

    func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            SoundEngine.shared.play("error"); return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    /// Hand the file to the existing flows: chat about it, or mail it.
    func ask(_ url: URL) {
        let state = AppState.shared
        state.droppedFile = DroppedFile(url: url, name: url.lastPathComponent)
        state.promptContext = .file(name: url.lastPathComponent, fileURL: url)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state.view = .prompt }
    }

    func mail(_ url: URL) {
        AppState.shared.droppedFile = DroppedFile(url: url, name: url.lastPathComponent)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { AppState.shared.view = .mail }
    }
}

// MARK: - Shelf view

struct ShelfView: View {
    @ObservedObject var state: AppState
    @ObservedObject var shelf = ShelfStore.shared

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: shelf.isTargeted ? .green : nil)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Shelf")
                        .font(.system(size: 12, weight: .semibold))
                    if !shelf.items.isEmpty {
                        Text("\(shelf.items.count)")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                    Spacer()
                    Toggle("Catch all drops", isOn: $shelf.catchesDrops)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .help("Files dragged onto the notch go to the shelf instead of the upload flow")
                    if !shelf.items.isEmpty {
                        IconButton(icon: "dot.radiowaves.left.and.right", help: "AirDrop all") { shelf.airDrop(shelf.items) }
                        IconButton(icon: "trash", help: "Clear shelf") { shelf.clear() }
                    }
                }
                if shelf.items.isEmpty {
                    emptyDropZone
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shelf.items, id: \.self) { ShelfTile(url: $0) }
                        }
                    }
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
    }

    private var emptyDropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(shelf.isTargeted ? Color(hex: "#22C55E").opacity(0.7) : Color.white.opacity(0.14),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .overlay(
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                    Text("Drop files here to keep them handy, drag them out anywhere")
                }
                .font(.system(size: 11.5))
                .foregroundColor(shelf.isTargeted ? Color(hex: "#34D399") : Color(hex: "#8E939C"))
            )
            .frame(maxHeight: .infinity)
    }
}

private struct ShelfTile: View {
    let url: URL
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 34, height: 34)
            Text(url.lastPathComponent)
                .font(.system(size: 9.5))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 66, height: 56)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovered ? 0.08 : 0.03)))
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button { ShelfStore.shared.remove(url) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
                .padding(2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("AirDrop") { ShelfStore.shared.airDrop([url]) }
            Divider()
            Button("Ask Mochi about it") { ShelfStore.shared.ask(url) }
            Button("Send by mail") { ShelfStore.shared.mail(url) }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
            Divider()
            Button("Remove from shelf") { ShelfStore.shared.remove(url) }
        }
    }
}

/// Small round icon button used by the Shelf and Clipboard headers.
struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(hovered ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                .frame(width: 22, height: 20)
                .background(Color.white.opacity(hovered ? 0.1 : 0.05))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
