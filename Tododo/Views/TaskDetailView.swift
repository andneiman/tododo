import SwiftUI

struct TaskDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskID: String

    @State private var title = ""
    @State private var newStep = ""
    @FocusState private var stepFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let task = store.record(taskID) {
                    form(task)
                } else {
                    ContentUnavailableView("Задача удалена", systemImage: "trash")
                }
            }
            .navigationTitle("Задача")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
        .onAppear { title = store.record(taskID)?.title ?? "" }
        .onDisappear { store.rename(taskID, to: title) }
    }

    private func form(_ task: Record) -> some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button {
                        store.toggleDone(task.id)
                    } label: {
                        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 23, weight: .light))
                            .foregroundStyle(task.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    TextField("Название", text: $title, prompt: Text("Название"), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .onSubmit { store.rename(taskID, to: title) }
                }

                ForEach(store.steps(of: task.id)) { step in
                    HStack(spacing: 12) {
                        Button {
                            store.toggleStep(step.id)
                        } label: {
                            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(step.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        }
                        .buttonStyle(.plain)
                        Text(step.title)
                            .strikethrough(step.isDone)
                            .foregroundStyle(step.isDone ? .secondary : .primary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Удалить", systemImage: "trash", role: .destructive) { store.deleteStep(step.id) }
                    }
                }

                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                    TextField("Следующий шаг", text: $newStep, prompt: Text("Следующий шаг"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .focused($stepFocused)
                        .submitLabel(.done)
                        .onSubmit(addStep)
                }
            }

            Section {
                Button {
                    store.toggleMyDay(task.id)
                } label: {
                    Label(task.isMyDay ? "В «Моём дне»" : "Добавить в «Мой день»", systemImage: task.isMyDay ? "sun.max.fill" : "sun.max")
                }
                Button {
                    store.toggleImportant(task.id)
                } label: {
                    Label(task.isImportant ? "Важная" : "Отметить важной", systemImage: task.isImportant ? "star.fill" : "star")
                }
                Picker(selection: listBinding(task)) {
                    Text(Store.inboxName).tag(Store.inboxID)
                    ForEach(store.lists) { list in
                        Text(list.title).tag(list.id)
                    }
                } label: {
                    Label("Список", systemImage: "list.bullet")
                }
            }

            Section {
                Button("Удалить задачу", systemImage: "trash", role: .destructive) {
                    store.deleteTask(task.id)
                    dismiss()
                }
            } footer: {
                if let created = task.data.createdAt {
                    Text("Создана \(Date(timeIntervalSince1970: created / 1000).formatted(date: .abbreviated, time: .shortened))")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func listBinding(_ task: Record) -> Binding<String> {
        Binding(
            get: {
                guard let id = task.data.listId, store.record(id) != nil else { return Store.inboxID }
                return id
            },
            set: { store.moveTask(task.id, toList: $0) }
        )
    }

    private func addStep() {
        store.addStep(to: taskID, title: newStep)
        newStep = ""
        DispatchQueue.main.async { stepFocused = true }
    }
}
