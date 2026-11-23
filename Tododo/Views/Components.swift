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
            // Bottom only: on the Mac the list runs up to the window top (no toolbar), so a top fade would hide the title.
            self.scrollEdgeEffectStyle(.soft, for: .bottom)
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
    /// Mac: called when the title starts being edited in place, so the row gets selected too.
    var onEditTitle: (() -> Void)? = nil

    @State private var hovering = false
    @State private var titleDraft = ""
    @State private var editingTitle = false
    /// Checked but not yet moved away: the row shows the tick for a beat, then leaves smoothly.
    @State private var completing = false

    private var shownDone: Bool { task.isDone || completing }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CheckButton(done: shownDone) { complete() }

            VStack(alignment: .leading, spacing: 2) {
                titleView
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !task.isDone {
                    ForEach(store.starredSteps(of: task.id)) { step in
                        StarredStepLine(step: step)
                    }
                }

            }

            Spacer(minLength: 8)

            if task.isImportant || hovering {
                Button {
                    store.star(task.id)
                } label: {
                    Image(systemName: task.isImportant ? "star.fill" : "star")
                        .foregroundStyle(task.isImportant ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.borderless)
                .help(task.isImportant ? "Remove from Important" : "Mark as Important")
            }
        }
        .padding(.vertical, rowPadding)
        .opacity(store.liftingID == task.id ? 0 : (completing ? 0.6 : 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: task.isDone) { _, _ in completing = false }
        .swipeActions(edge: .trailing) {
            #if os(iOS)
            // iPhone: swiping left stars the task (and lifts it to the top); delete lives in the long-press menu.
            Button(task.isImportant ? "Unstar" : "Star", systemImage: task.isImportant ? "star.slash" : "star.fill") {
                store.star(task.id)
            }
            .tint(.orange)
            #else
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation(.taskLeave) { store.deleteTask(task.id) }
            }
            #endif
        }
        .swipeActions(edge: .leading) {
            Button(task.isMyDay ? "Remove from My Day" : "Add to My Day", systemImage: "sun.max") {
                withAnimation(.taskLeave) { store.toggleMyDay(task.id) }
            }
            .tint(.orange)
        }
        #if os(macOS)
        .contextMenu { TaskMenu(task: task) }   // iPhone: long press only drags
        #endif
    }

    /// iPhone: plain text (tap opens the task). Mac: edit the title right in the row.
    @ViewBuilder private var titleView: some View {
        #if os(macOS)
        if editingTitle {
            // Single-line plain field: no white box inside the highlighted row.
            InlineTextField(text: $titleDraft) {
                commitTitle()
                editingTitle = false
            }
        } else {
            titleText
                .onTapGesture {
                    // Click the title to rename it right here (open tasks); the row gets selected too.
                    onEditTitle?()
                    guard !task.isDone else { return }
                    titleDraft = task.title
                    editingTitle = true
                }
        }
        #else
        titleText
        #endif
    }

    /// Title, then the step count in gray: "Кипр (3 / 12)".
    private var titleText: some View {
        var t = Text(task.title).foregroundColor(shownDone ? .secondary : Color.label)
        if let p = store.stepProgress(of: task.id) {
            t = t + Text(" (\(p.done)/\(p.total))").foregroundColor(Color.secondary.opacity(0.5))
        }
        return t.strikethrough(completing, color: .secondary)
    }

    private func commitTitle() {
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == task.title { return }
        store.rename(task.id, to: t)
    }

    /// Completing: tick + strike-through first, then the row glides out of the list.
    /// Reopening a completed task moves it back right away.
    private func complete() {
        guard !completing else { return }
        guard !task.isDone else {
            withAnimation(.taskLeave) { store.toggleDone(task.id) }
            return
        }
        withAnimation(.snappy(duration: 0.2)) { completing = true }
        let id = task.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.taskLeave) { store.toggleDone(id) }
        }
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
            // My Day is a plan for today; which list a task lives in is noise there.
            if case .myDay = scope { showsList = false }
        }
        if showsList { parts.append(store.listName(task.data.listId)) }
        if task.isMyDay && scope != .myDay { parts.append("My Day") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Shared by the context menu of task rows.
struct TaskMenu: View {
    @Environment(Store.self) private var store
    let task: Record

    var body: some View {
        Button(task.isDone ? "Mark as Not Completed" : "Mark as Completed", systemImage: "checkmark.circle") {
            withAnimation(.taskLeave) { store.toggleDone(task.id) }
        }
        Button(task.isMyDay ? "Remove from My Day" : "Add to My Day", systemImage: "sun.max") {
            withAnimation(.taskLeave) { store.toggleMyDay(task.id) }
        }
        Button(task.isImportant ? "Remove from Important" : "Mark as Important", systemImage: "star") {
            store.star(task.id)
        }
        Menu("Move to", systemImage: "folder") {
            Button(Store.inboxName) { withAnimation(.taskLeave) { store.moveTask(task.id, toList: Store.inboxID) } }
            ForEach(store.lists) { list in
                Button(list.title) { withAnimation(.taskLeave) { store.moveTask(task.id, toList: list.id) } }
            }
        }
        Divider()
        Button("Delete Task", systemImage: "trash", role: .destructive) {
            withAnimation(.taskLeave) { store.deleteTask(task.id) }
        }
    }
}

// MARK: - Selection

/// A quiet, rounded highlight for the selected task instead of the heavy system selection.
struct SelectableRow: ViewModifier {
    let id: String
    @Binding var selection: String?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { selection = id }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selection == id ? Color.primary.opacity(0.035) : Color.clear)
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
    case black, gray, red, orange, green, teal, blue, indigo, purple, pink, brown

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .black: return .primary
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
        self = stored.flatMap(SectionColor.init(rawValue:)) ?? .black
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
            .inspectorColumnWidth(min: 308, ideal: 352, max: 484)
            // Same light gray as the sidebar (the default inspector gray is a touch darker).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(white: 0.965).ignoresSafeArea())
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

extension Animation {
    /// How a task leaves (or joins) a list: completed, moved, unstarred, removed from My Day, deleted.
    static let taskLeave: Animation = .easeInOut(duration: 0.35)
}

extension Store {
    /// Star / unstar with a tidy animation. Starring lifts the task to the top: the row
    /// fades out where it is, the other rows slide down to make room, then it fades in at the top.
    func star(_ id: String) {
        guard let task = record(id), !task.isImportant, !task.isDone, liftingID == nil else {
            withAnimation(.taskLeave) { toggleImportant(id) }
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { liftingID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.35)) { self.toggleImportant(id) }
            self.scrollTarget = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeIn(duration: 0.25)) { self.liftingID = nil }
            }
        }
    }
}

/// A starred step shown right under its task in a list: small circle to tick it off, quiet text.
struct StarredStepLine: View {
    @Environment(Store.self) private var store
    let step: Record
    @State private var ticking = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                guard !ticking else { return }
                withAnimation(.snappy(duration: 0.2)) { ticking = true }
                let id = step.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.taskLeave) { store.toggleStep(id) }
                }
            } label: {
                Image(systemName: ticking ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(ticking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18, height: Self.lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete step")
            Text(step.title)
                .font(Self.font)
                .strikethrough(ticking, color: .secondary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.top, Self.gap)
        .padding(.leading, 5)   // a touch to the right of the task text
    }

    // Mac: a point bigger and about 20% tighter than the iPhone sizes.
    #if os(macOS)
    static let font = Font.system(size: 12)
    static let lineHeight: CGFloat = 16.5
    static let gap: CGFloat = 0.5
    #else
    static let font = Font.subheadline
    static let lineHeight: CGFloat = 18
    static let gap: CGFloat = 1
    #endif
}

#if os(macOS)
import AppKit

/// A bare text field for renaming in place on the Mac: just a cursor in the text, no white editing box.
struct InlineTextField: NSViewRepresentable {
    @Binding var text: String
    let onEnd: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.isBordered = false
        f.drawsBackground = false
        f.backgroundColor = .clear
        f.focusRingType = .none
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.usesSingleLineMode = true
        f.delegate = context.coordinator
        DispatchQueue.main.async {
            f.window?.makeFirstResponder(f)
            if let editor = f.currentEditor() as? NSTextView {
                editor.drawsBackground = false
                editor.backgroundColor = .clear
                editor.selectedRange = NSRange(location: (f.stringValue as NSString).length, length: 0)
            }
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != text, f.currentEditor() == nil { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTextField
        init(_ p: InlineTextField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }
        func controlTextDidEndEditing(_ n: Notification) { parent.onEnd() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) {
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}
#endif

extension Color {
    /// The system text color. On the Mac this is the same softened black as text fields,
    /// so plain labels don't look darker or heavier than editable ones.
    static var label: Color {
        #if os(macOS)
        Color(nsColor: .labelColor)
        #else
        Color(uiColor: .label)
        #endif
    }
}
