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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
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
            TaskForm(task: task, onClose: onClose)
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
                        withAnimation(.snappy) { store.toggleDone(task.id) }
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
                Toggle(isOn: Binding(get: { task.isMyDay }, set: { _ in store.toggleMyDay(task.id) })) {
                    Label("My Day", systemImage: "sun.max")
                }
                Toggle(isOn: Binding(get: { task.isImportant }, set: { _ in store.toggleImportant(task.id) })) {
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
        guard let created = task.data.createdAt else { return "Task" }
        let date = Date(timeIntervalSince1970: created / 1000)
        return "Created \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private var listBinding: Binding<String> {
        Binding(
            get: {
                guard let id = task.data.listId, store.record(id) != nil else { return Store.inboxID }
                return id
            },
            set: { store.moveTask(task.id, toList: $0) }
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
        }
        .onHover { hovering = $0 }
        .onAppear { text = step.title }
        .onChange(of: text) { _, new in store.rename(step.id, to: new) }
        .contextMenu {
            Button("Delete Step", systemImage: "trash", role: .destructive) { store.deleteStep(step.id) }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteStep(step.id) }
        }
    }
}
