import SwiftUI
import UniformTypeIdentifiers

struct TaskDetailView: View {
    @Environment(Store.self) private var store
    let taskID: String
    let onClose: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle("Details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onClose)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        #else
        // No toolbar button: Esc, or a click on empty space, closes the details.
        content
            .onExitCommand(perform: onClose)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let task = store.record(taskID) {
            #if os(macOS)
            MacTaskPane(task: task, onClose: onClose)
            #else
            TaskForm(task: task, onClose: onClose)
            #endif
        } else {
            ContentUnavailableView("Task Deleted", systemImage: "trash")
        }
    }
}

private struct TaskForm: View {
    @Environment(Store.self) private var store
    let task: Record
    let onClose: () -> Void

    @State private var title = ""
    @State private var newStep = ""
    @FocusState private var stepFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CheckButton(done: task.isDone, size: 19) {
                        withAnimation(.taskLeave) { store.toggleDone(task.id) }
                    }
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 6 }
                    TextField("Title", text: $title, prompt: Text("Title"), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .strikethrough(task.isDone, color: .secondary)
                }
                .padding(.vertical, 2)

                ForEach(store.steps(of: task.id)) { step in
                    StepRow(step: step)
                }
                // Press and hold a step, then drag it up or down.
                .onMove { store.reorderSteps(of: task.id, from: $0, to: $1) }

                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    TextField("Add Step", text: $newStep, prompt: Text("Add Step"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .focused($stepFocused)
                        .submitLabel(.done)
                        .onSubmit(addStep)
                        .noAutoCapitals()   // steps start small unless you press Shift
                }
            }

            Section {
                NoteField(task: task)
            }

            Section {
                Toggle(isOn: Binding(get: { task.isMyDay }, set: { _ in store.myDay(task.id) })) {
                    Label("My Day", systemImage: "sun.max")
                }
                Toggle(isOn: Binding(get: { task.isImportant }, set: { _ in store.star(task.id) })) {
                    Label("Important", systemImage: "star")
                }
                Picker(selection: listBinding) {
                    Text(Store.inboxName).tag(Store.inboxID)
                    ForEach(store.lists) { list in
                        Text(list.title).tag(list.id)
                    }
                } label: {
                    Label("List", systemImage: "list.bullet")
                }
                CopyAgentLinkButton(taskID: task.id) { copied in
                    Label(copied ? "Link Copied" : "Copy Link for AI Agent", systemImage: copied ? "checkmark" : "link")
                }
            }

            Section {
                LabeledContent {
                    Button(role: .destructive) {
                        store.deleteTask(task.id)
                        onClose()
                    } label: {
                        Label("Delete Task", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete Task")
                } label: {
                    Text(createdText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { title = task.title }
        // A typed step is kept even without pressing return: on close, on Done, on switching tasks, on tapping away.
        .onDisappear { saveDraftStep(for: task.id) }
        .onChange(of: task.id) { old, _ in saveDraftStep(for: old) }
        .onChange(of: stepFocused) { _, focused in if !focused { saveDraftStep(for: task.id) } }
        .onChange(of: title) { _, new in
            let flat = new.replacingOccurrences(of: "\n", with: " ")
            if flat != new {
                title = flat
                return
            }
            store.rename(task.id, to: flat)
        }
    }

    private var createdText: String {
        guard let created = task.data.createdAt else { return "" }
        let date = Date(timeIntervalSince1970: created / 1000)
        return "Created \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private var listBinding: Binding<String> {
        Binding(
            get: {
                guard let id = task.data.listId, store.record(id) != nil else { return Store.inboxID }
                return id
            },
            set: { id in withAnimation(.taskLeave) { store.moveTask(task.id, toList: id) } }
        )
    }

    private func addStep() {
        store.addStep(to: task.id, title: newStep)
        newStep = ""
        DispatchQueue.main.async { stepFocused = true }
    }

    private func saveDraftStep(for id: String) {
        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        newStep = ""
        guard !text.isEmpty, store.record(id) != nil else { return }
        store.addStep(to: id, title: text)
    }
}

private struct StepRow: View {
    @Environment(Store.self) private var store
    let step: Record
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var editing: Bool
    @State private var macEditing = false

    #if os(macOS)
    static let circle: CGFloat = 14.5   // a touch smaller in the Mac pane
    static let alwaysField = false
    static let doneStyle = HierarchicalShapeStyle.secondary
    #else
    static let circle: CGFloat = 16
    static let alwaysField = true
    static let doneStyle = HierarchicalShapeStyle.tertiary   // clearly lighter than open steps
    #endif

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CheckButton(done: step.isDone, size: Self.circle) { store.toggleStep(step.id) }
                // The circle's middle lines up with the middle of the first text line.
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 }
            if step.isDone {
                // Completed steps read gray (text fields ignore the color on the Mac).
                Text(step.title)
                    .foregroundStyle(Self.doneStyle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if Self.alwaysField {
                // iPhone: long steps wrap onto new lines; Return just ends editing.
                TextField("Step", text: $text, axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .lineLimit(1...)
                    .focused($editing)
                    .noAutoCapitals()
            } else if macEditing {
                #if os(macOS)
                // Mac: a bare field (no stray empty line, no white box) while renaming.
                InlineTextField(text: $text) {
                    commit()
                    macEditing = false
                }
                #endif
            } else {
                // Mac: plain text until clicked (a wrapping text field adds a stray empty line on the Mac).
                Text(step.title)
                    .foregroundStyle(Color.label)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { text = step.title; macEditing = true }
            }
            HStack(spacing: 2) {
                #if os(macOS)
                // Always laid out, only shown on hover, so the row never changes size.
                Button { store.deleteStep(step.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Delete Step")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                #endif
                Button {
                    withAnimation(.snappy) { store.toggleStepStar(step.id) }
                } label: {
                    Image(systemName: step.isImportant ? "eye.fill" : "eye")
                        .font(.system(size: 13))
                        .foregroundStyle(step.isImportant ? AnyShapeStyle(Color.primary.opacity(0.7)) : AnyShapeStyle(.tertiary))
                        .frame(width: 26, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(step.isImportant ? "Hide from the list" : "Show under the task in the list")
                // Always laid out (hidden when not needed), so hovering never shifts the row.
                .opacity(showsStar ? 1 : 0)
                .allowsHitTesting(showsStar)
            }
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 }
        }
        .onHover { hovering = $0 }
        .onAppear { text = step.title }
        .onChange(of: step.title) { _, new in if !editing { text = new } }
        .onChange(of: text) { _, new in
            if new.contains("\n") {
                text = new.replacingOccurrences(of: "\n", with: "")
                editing = false
            }
        }
        // Saved when editing ends (Return, tapping another step, closing): an emptied step is deleted.
        .onChange(of: editing) { _, now in if !now { commit(); macEditing = false } }
        .onDisappear { commit() }
        #if os(macOS)
        .contextMenu {
            Button(step.isImportant ? "Hide from List" : "Show in List", systemImage: step.isImportant ? "eye.slash" : "eye") {
                withAnimation(.snappy) { store.toggleStepStar(step.id) }
            }
            Button("Delete Step", systemImage: "trash", role: .destructive) { store.deleteStep(step.id) }
        }
        #endif
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteStep(step.id) }
        }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.record(step.id) != nil else { return }
        if t.isEmpty { store.deleteStep(step.id) }
        else if t != step.title { store.rename(step.id, to: t) }
    }

    /// iPhone: always (no hover). Mac: when starred or under the pointer.
    private var showsStar: Bool {
        guard !step.isDone else { return false }   // completed steps have no eye
        #if os(iOS)
        return true
        #else
        return step.isImportant || hovering
        #endif
    }
}

#if os(macOS)
/// The Mac details pane: one quiet column in the spirit of Microsoft To Do and Reminders,
/// without grouped cards or switches.
private struct MacTaskPane: View {
    @Environment(Store.self) private var store
    let task: Record
    let onClose: () -> Void
    @State private var paneHeight: CGFloat = 0

    @State private var title = ""
    @State private var newStep = ""
    @FocusState private var stepFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        CheckButton(done: task.isDone, size: 18) {
                            withAnimation(.taskLeave) { store.toggleDone(task.id) }
                        }
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
                        TextField("Title", text: $title, prompt: Text("Title"), axis: .vertical)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(task.isDone ? .secondary : .primary)
                    }
                    .padding(.bottom, 12)

                    ForEach(store.steps(of: task.id)) { step in
                        StepRow(step: step)
                            .padding(.vertical, 3)
                            // Drag a step onto another to put it there.
                            .draggable(StepDrag(id: step.id)) {
                                Text(step.title).padding(6).background(.background, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .dropDestination(for: StepDrag.self) { items, _ in
                                guard let item = items.first, item.id != step.id else { return false }
                                withAnimation(.snappy) { store.moveStep(item.id, before: step.id) }
                                return true
                            }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        TextField("Add Step", text: $newStep, prompt: Text("Add Step"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .focused($stepFocused)
                            .onSubmit(addStep)
                    }
                    .padding(.vertical, 5)

                    Divider()
                        .padding(.vertical, 12)

                    NoteField(task: task)
                        .padding(.bottom, 12)
                    PaneRow(
                        icon: task.isMyDay ? "sun.max.fill" : "sun.max",
                        title: task.isMyDay ? "Added to My Day" : "Add to My Day",
                        tint: task.isMyDay ? .accentColor : nil
                    ) {
                        store.myDay(task.id)
                    }
                    PaneRow(
                        icon: task.isImportant ? "star.fill" : "star",
                        title: task.isImportant ? "Important" : "Mark as Important",
                        tint: task.isImportant ? .orange : nil
                    ) {
                        store.star(task.id)
                    }
                    Menu {
                        Button(Store.inboxName) { withAnimation(.taskLeave) { store.moveTask(task.id, toList: Store.inboxID) } }
                        if !store.lists.isEmpty { Divider() }
                        ForEach(store.lists) { list in
                            Button(list.title) { withAnimation(.taskLeave) { store.moveTask(task.id, toList: list.id) } }
                        }
                    } label: {
                        PaneLabel(icon: "list.bullet", title: store.listName(task.data.listId), tint: nil, trailing: "chevron.up.chevron.down")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    CopyAgentLinkButton(taskID: task.id) { copied in
                        PaneLabel(icon: copied ? "checkmark" : "link", title: copied ? "Link Copied" : "Copy Link for AI Agent",
                                  tint: copied ? .green : nil, trailing: nil)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, minHeight: paneHeight, alignment: .topLeading)
                // Clicking empty space in the pane closes it.
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { onClose() })
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)   // big, forgiving click area
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .padding(.top, 2)
                .padding(.trailing, 4)
            }

            Divider()
            HStack {
                Text(createdText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.deleteTask(task.id)
                    onClose()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete Task")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        // Clicking empty space in the pane closes it.
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { onClose() })
        .onAppear { title = task.title }
        // A typed step is kept even without pressing return: on close, on Done, on switching tasks, on tapping away.
        .onDisappear { saveDraftStep(for: task.id) }
        .onChange(of: task.id) { old, _ in saveDraftStep(for: old) }
        .onChange(of: stepFocused) { _, focused in if !focused { saveDraftStep(for: task.id) } }
        .onChange(of: title) { _, new in
            let flat = new.replacingOccurrences(of: "\n", with: " ")
            if flat != new {
                title = flat
                return
            }
            store.rename(task.id, to: flat)
        }
    }

    private var createdText: String {
        guard let created = task.data.createdAt else { return "" }
        let date = Date(timeIntervalSince1970: created / 1000)
        return "Created \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func addStep() {
        store.addStep(to: task.id, title: newStep)
        newStep = ""
        DispatchQueue.main.async { stepFocused = true }
    }

    private func saveDraftStep(for id: String) {
        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        newStep = ""
        guard !text.isEmpty, store.record(id) != nil else { return }
        store.addStep(to: id, title: text)
    }
}

/// One action line in the Mac details pane: icon, text, a soft highlight on hover.
private struct PaneRow: View {
    let icon: String
    let title: String
    let tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PaneLabel(icon: icon, title: title, tint: tint, trailing: nil)
        }
        .buttonStyle(.plain)
    }
}

private struct PaneLabel: View {
    let icon: String
    let title: String
    let tint: Color?
    let trailing: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                .frame(width: 22)
            Text(title)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
            Spacer(minLength: 8)
            if let trailing {
                Image(systemName: trailing)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
#endif


// MARK: - Note and AI link

/// Free-form note of a task. Saved as you type.
private struct NoteField: View {
    @Environment(Store.self) private var store
    let task: Record
    @State private var text = ""

    var body: some View {
        TextField("Note", text: $text, prompt: Text("Add Note"), axis: .vertical)
            .labelsHidden()
            .textFieldStyle(.plain)
            .lineLimit(2...)
            .onAppear { text = task.data.note ?? "" }
            .onChange(of: task.id) { _, _ in text = task.data.note ?? "" }
            .onChange(of: text) { _, new in store.setNote(task.id, to: new) }
    }
}

/// Copies a link an AI agent (ChatGPT, Claude…) can open to read everything about the task: title, list, steps, note.
private struct CopyAgentLinkButton<Label: View>: View {
    let taskID: String
    @ViewBuilder let label: (_ copied: Bool) -> Label
    @State private var copied = false

    var body: some View {
        Button {
            guard let config = Config.current else { return }
            let link = config.agentLink(forTask: taskID).absoluteString
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            #else
            UIPasteboard.general.string = link
            #endif
            withAnimation(.snappy) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation(.snappy) { copied = false } }
        } label: {
            label(copied)
        }
        .disabled(Config.current == nil)
        .help("Copies a link that ChatGPT or Claude can open to read this task")
    }
}

/// What a dragged step carries (its id), for reordering steps on the Mac.
struct StepDrag: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

extension View {
    /// iPhone keyboard: don't capitalize the first letter on its own (Shift still works). No-op on the Mac.
    func noAutoCapitals() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
