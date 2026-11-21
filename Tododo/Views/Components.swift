import SwiftUI

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass capsule on iOS 26 / macOS 26, a quiet material capsule before that.
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }

    /// Content fades softly under floating glass controls.
    @ViewBuilder
    func softScrollEdges() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            #if os(macOS)
            self.scrollEdgeEffectStyle(.soft, for: .all)
            #else
            self.scrollEdgeEffectStyle(.soft, for: .bottom)
            #endif
        } else {
            self
        }
    }

    /// The list draws its own large title on the Mac, so the window toolbar stays clean.
    @ViewBuilder
    func hidesToolbarTitle() -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            self.toolbar(removing: .title)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - Controls

/// The round completion button used by tasks and steps.
struct CheckButton: View {
    let done: Bool
    var size: CGFloat = 19
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size, weight: .light))
                .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size + 6, height: size + 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Mark as not completed" : "Mark as completed")
    }
}

/// Large title at the top of a list on the Mac, in the spirit of Reminders.
struct ListHeader: View {
    let title: String
    var subtitle: String?
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 26, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }
}

// MARK: - Sync status

extension Store {
    var syncSymbol: String {
        switch syncStatus {
        case .notConfigured: return "exclamationmark.icloud"
        case .offline: return "icloud.slash"
        case .syncing: return "arrow.clockwise.icloud"
        case .idle: return "icloud"
        case .ok: return pendingCount > 0 ? "arrow.clockwise.icloud" : "checkmark.icloud"
        }
    }

    var syncText: String {
        switch syncStatus {
        case .notConfigured: return "Sync is not set up"
        case .offline: return pendingCount > 0 ? "Offline · \(pendingCount) waiting to upload" : "Offline"
        case .syncing: return "Syncing…"
        case .idle: return "Waiting to sync"
        case .ok(let date):
            return pendingCount > 0 ? "Syncing…" : "Up to date · \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

    var syncNeedsAttention: Bool {
        switch syncStatus {
        case .notConfigured, .offline: return true
        default: return false
        }
    }
}

// MARK: - Task row

struct TaskRow: View {
    @Environment(Store.self) private var store
    let task: Record
    /// The screen the row is on; `nil` in search results.
    let scope: Scope?

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CheckButton(done: task.isDone) {
                withAnimation(.snappy) { store.toggleDone(task.id) }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if task.isImportant || hovering {
                Button {
                    store.toggleImportant(task.id)
                } label: {
                    Image(systemName: task.isImportant ? "star.fill" : "star")
                        .foregroundStyle(task.isImportant ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.borderless)
                .help(task.isImportant ? "Remove from Important" : "Mark as Important")
            }
        }
        .padding(.vertical, rowPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteTask(task.id) }
        }
        .swipeActions(edge: .leading) {
            Button(task.isMyDay ? "Remove from My Day" : "Add to My Day", systemImage: "sun.max") {
                store.toggleMyDay(task.id)
            }
            .tint(.orange)
        }
        .contextMenu { TaskMenu(task: task) }
    }

    private var rowPadding: CGFloat {
        #if os(macOS)
        return 5
        #else
        return 1
        #endif
    }

    private var subtitle: String? {
        var parts: [String] = []
        var showsList = true
        if let scope {
            if case .inbox = scope { showsList = false }
            if case .list = scope { showsList = false }
        }
        if showsList { parts.append(store.listName(task.data.listId)) }
        if task.isMyDay && scope != .myDay { parts.append("My Day") }
        if let p = store.stepProgress(of: task.id) { parts.append("\(p.done) of \(p.total)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Shared by the context menu of task rows.
struct TaskMenu: View {
    @Environment(Store.self) private var store
    let task: Record

    var body: some View {
        Button(task.isDone ? "Mark as Not Completed" : "Mark as Completed", systemImage: "checkmark.circle") {
            store.toggleDone(task.id)
        }
        Button(task.isMyDay ? "Remove from My Day" : "Add to My Day", systemImage: "sun.max") {
            store.toggleMyDay(task.id)
        }
        Button(task.isImportant ? "Remove from Important" : "Mark as Important", systemImage: "star") {
            store.toggleImportant(task.id)
        }
        Menu("Move to", systemImage: "folder") {
            Button(Store.inboxName) { store.moveTask(task.id, toList: Store.inboxID) }
            ForEach(store.lists) { list in
                Button(list.title) { store.moveTask(task.id, toList: list.id) }
            }
        }
        Divider()
        Button("Delete Task", systemImage: "trash", role: .destructive) { store.deleteTask(task.id) }
    }
}

// MARK: - Selection

/// A quiet, rounded highlight for the selected task instead of the heavy system selection.
struct SelectableRow: ViewModifier {
    let id: String
    @Binding var selection: String?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { selection = selection == id ? nil : id }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selection == id ? Color.accentColor.opacity(0.12) : Color.clear)
                    .padding(.horizontal, 6)
            )
    }
}

extension View {
    func selectable(_ id: String, selection: Binding<String?>) -> some View {
        modifier(SelectableRow(id: id, selection: selection))
    }
}

// MARK: - Section colors

enum SectionColor: String, CaseIterable, Identifiable {
    case gray, red, orange, green, teal, blue, indigo, purple, pink, brown

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .gray: return .secondary
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .brown: return .brown
        }
    }

    init(stored: String?) {
        self = stored.flatMap(SectionColor.init(rawValue:)) ?? .gray
    }
}

// MARK: - Inspector

/// Shows the selected task's details: a trailing inspector on the Mac, a sheet on iPhone.
/// The sheet keeps its own copy of the task id, so it never goes blank while being swiped away.
struct TaskInspector: ViewModifier {
    @Environment(Store.self) private var store
    @Binding var selection: String?

    func body(content: Content) -> some View {
        #if os(macOS)
        content.inspector(isPresented: shown) {
            Group {
                if let id = selection {
                    TaskDetailView(taskID: id) { selection = nil }
                        .id(id)
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
        }
        #else
        content.sheet(item: sheetItem) { ref in
            TaskDetailView(taskID: ref.id) { selection = nil }
        }
        #endif
    }

    private var sheetItem: Binding<TaskRef?> {
        Binding(
            get: {
                guard let id = selection, let task = store.record(id), !task.isSection else { return nil }
                return TaskRef(id: id)
            },
            set: { selection = $0?.id }
        )
    }

    private var shown: Binding<Bool> {
        Binding(
            get: {
                guard let id = selection, let task = store.record(id) else { return false }
                return !task.isSection
            },
            set: { if !$0 { selection = nil } }
        )
    }
}

// MARK: - Search

struct SearchResultsView: View {
    @Environment(Store.self) private var store
    let query: String
    @State private var selectedTask: String?

    var body: some View {
        let results = store.search(query)
        List {
            ListHeader(title: "Search", subtitle: results.count == 1 ? "1 result" : "\(results.count) results")
            ForEach(results) { task in
                TaskRow(task: task, scope: nil)
                    .selectable(task.id, selection: $selectedTask)
            }
        }
        .listStyle(.inset)
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle("Search")
        .hidesToolbarTitle()
        .modifier(TaskInspector(selection: $selectedTask))
    }
}
