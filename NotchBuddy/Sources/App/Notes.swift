import SwiftUI

// MARK: - Quick notes + to-dos (kept in UserDefaults; plain user text, no secrets)

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    struct Todo: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var done = false
    }

    @Published var notes: String = UserDefaults.standard.string(forKey: "quickNotes") ?? "" {
        didSet { UserDefaults.standard.set(notes, forKey: "quickNotes") }
    }
    @Published private(set) var todos: [Todo] = {
        guard let data = UserDefaults.standard.data(forKey: "quickTodos"),
              let list = try? JSONDecoder().decode([Todo].self, from: data) else { return [] }
        return list
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(todos), forKey: "quickTodos") }
    }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        todos.insert(Todo(text: t), at: 0)
    }

    func toggle(_ todo: Todo) {
        guard let i = todos.firstIndex(of: todo) else { return }
        todos[i].done.toggle()
        if todos[i].done { SoundEngine.shared.play("approve") }
        // Done items sink to the bottom.
        todos.sort { !$0.done && $1.done }
    }

    func remove(_ todo: Todo) { todos.removeAll { $0.id == todo.id } }
    func clearDone() { todos.removeAll(where: \.done) }
}

struct NotesView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store = NotesStore.shared
    @State private var draft = ""

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            HStack(alignment: .top, spacing: 10) {
                todoColumn.frame(width: 250)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.system(size: 11, weight: .semibold))
                    TextEditor(text: $store.notes)
                        .font(.system(size: 11.5))
                        .scrollContentBackgroundHidden()
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
    }

    private var todoColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("To-do").font(.system(size: 11, weight: .semibold))
                let open = store.todos.filter { !$0.done }.count
                if open > 0 { Text("\(open)").font(.system(size: 10.5)).foregroundColor(Color(hex: "#6B7079")) }
                Spacer()
                if store.todos.contains(where: \.done) {
                    Button("Clear done") { store.clearDone() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
                }
            }
            TextField("Add a to-do and press Return", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                .onSubmit {
                    store.add(draft)
                    draft = ""
                }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.todos) { TodoRow(todo: $0) }
                }
            }
        }
    }
}

private struct TodoRow: View {
    let todo: NotesStore.Todo
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button { NotesStore.shared.toggle(todo) } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(todo.done ? Color(hex: "#34D399") : Color(hex: "#8E939C"))
            }
            .buttonStyle(.plain)
            Text(todo.text)
                .font(.system(size: 11.5))
                .strikethrough(todo.done)
                .foregroundColor(todo.done ? Color(hex: "#6B7079") : Color(hex: "#E5E7EB"))
                .lineLimit(2)
            Spacer(minLength: 0)
            if hovered {
                Button { NotesStore.shared.remove(todo) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).foregroundColor(Color(hex: "#8E939C"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .onHover { hovered = $0 }
    }
}
