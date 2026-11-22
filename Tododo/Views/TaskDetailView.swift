import SwiftUI

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
        content
            .onExitCommand(perform: onClose)
            .toolbar {
                ToolbarItem {
                    Button(action: onClose) {
                        Label("Hide Details", systemImage: "sidebar.trailing")
                    }
                    .help("Hide Details (Esc)")
                }
            }
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
                }
            }

            Section {
                Toggle(isOn: Binding(get: { task.isMyDay }, set: { _ in withAnimation(.taskLeave) { store.toggleMyDay(task.id) } })) {
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
}

private struct StepRow: View {
    @Environment(Store.self) private var store
    let step: Record
    @State private var text = ""
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            CheckButton(done: step.isDone, size: 16) { store.toggleStep(step.id) }
            TextField("Step", text: $text, prompt: Text("Step"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .foregroundStyle(step.isDone ? .secondary : .primary)
            if hovering {
                Button { store.deleteStep(step.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Delete Step")
            }
            if showsStar {
                Button {
                    withAnimation(.snappy) { store.toggleStepStar(step.id) }
                } label: {
                    Image(systemName: step.isImportant ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(step.isImportant ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.borderless)
                .help(step.isImportant ? "Hide from the list" : "Show under the task in the list")
            }
        }
        .onHover { hovering = $0 }
        .onAppear { text = step.title }
        .onChange(of: text) { _, new in store.rename(step.id, to: new) }
        .contextMenu {
            Button(step.isImportant ? "Unstar Step" : "Star Step", systemImage: step.isImportant ? "star.slash" : "star") {
                withAnimation(.snappy) { store.toggleStepStar(step.id) }
            }
            Button("Delete Step", systemImage: "trash", role: .destructive) { store.deleteStep(step.id) }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteStep(step.id) }
        }
    }

    /// iPhone: always (no hover). Mac: when starred or under the pointer.
    private var showsStar: Bool {
        guard !step.isDone else { return step.isImportant }
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

                    PaneRow(
                        icon: task.isMyDay ? "sun.max.fill" : "sun.max",
                        title: task.isMyDay ? "Added to My Day" : "Add to My Day",
                        tint: task.isMyDay ? .accentColor : nil
                    ) {
                        withAnimation(.taskLeave) { store.toggleMyDay(task.id) }
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
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 20)
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
        .onAppear { title = task.title }
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
