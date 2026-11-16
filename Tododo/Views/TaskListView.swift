import SwiftUI

struct TaskListView: View {
    @Environment(Store.self) private var store
    let scope: Scope

    @State private var draft = ""
    @State private var showDone = false
    @State private var detail: TaskRef?
    @State private var renaming: TaskRef?
    @State private var renameText = ""
    @FocusState private var adding: Bool

    var body: some View {
        let tasks = store.tasks(in: scope)
        let mover: ((IndexSet, Int) -> Void)? = scope == .important ? nil : { store.reorder(in: scope, from: $0, to: $1) }
        List {
            ForEach(tasks.open) { item in
                row(item)
            }
            .onMove(perform: mover)

            if !tasks.done.isEmpty {
                Button {
                    withAnimation { showDone.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showDone ? 90 : 0))
                        Text("Завершённые")
                        Text("\(tasks.done.count)")
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)

                if showDone {
                    ForEach(tasks.done) { item in
                        row(item)
                    }
                }
            }

            if tasks.open.isEmpty && tasks.done.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(store.title(of: scope))
        .safeAreaInset(edge: .bottom) { addBar }
        .refreshable { await store.sync() }
        .sensoryFeedback(.success, trigger: store.doneTick)
        .sheet(item: $detail) { TaskDetailView(taskID: $0.id) }
        .alert("Отбивка", isPresented: renameShown, presenting: renaming) { ref in
            TextField("Название", text: $renameText)
            Button("Готово") { store.rename(ref.id, to: renameText) }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(_ item: Record) -> some View {
        if item.isSection {
            SectionDivider(title: item.title)
                .contentShape(Rectangle())
                .onTapGesture { startRename(item) }
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Удалить", systemImage: "trash", role: .destructive) { store.deleteTask(item.id) }
                }
                .contextMenu {
                    Button("Переименовать", systemImage: "pencil") { startRename(item) }
                    Button("Удалить отбивку", systemImage: "trash", role: .destructive) { store.deleteTask(item.id) }
                }
        } else {
            TaskRow(task: item, scope: scope) { detail = TaskRef(id: item.id) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: scope == .myDay ? "sun.max" : "checkmark.circle")
                .font(.system(size: 40, weight: .ultraLight))
            Text(scope == .myDay ? "Что сделаем сегодня?" : "Пока пусто")
                .font(.subheadline)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var addBar: some View {
        let isSection = draft.hasPrefix("#")
        return HStack(spacing: 10) {
            Image(systemName: isSection ? "number" : "plus")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            TextField(isSection ? "Название отбивки" : "Добавить задачу", text: $draft)
                .focused($adding)
                .submitLabel(.done)
                .onSubmit(submit)
            if isSection {
                Text("отбивка")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func submit() {
        let text = draft
        draft = ""
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        withAnimation { store.addTask(text, in: scope) }
        // Keep the keyboard up for the next task.
        DispatchQueue.main.async { adding = true }
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func startRename(_ item: Record) {
        renameText = item.title
        renaming = TaskRef(id: item.id)
    }
}

/// A divider between blocks of tasks, like "Сделать" and "Подумать".
struct SectionDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .padding(.top, 18)
        .padding(.bottom, 2)
    }
}

struct TaskRow: View {
    @Environment(Store.self) private var store
    let task: Record
    /// The screen the row is shown on; `nil` in search results.
    let scope: Scope?
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { store.toggleDone(task.id) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(task.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Вернуть в работу" : "Завершить")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            Button {
                store.toggleImportant(task.id)
            } label: {
                Image(systemName: task.isImportant ? "star.fill" : "star")
                    .foregroundStyle(task.isImportant ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Важное")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .swipeActions(edge: .trailing) {
            Button("Удалить", systemImage: "trash", role: .destructive) { store.deleteTask(task.id) }
        }
        .swipeActions(edge: .leading) {
            Button(task.isMyDay ? "Убрать" : "Мой день", systemImage: task.isMyDay ? "sun.max.fill" : "sun.max") {
                store.toggleMyDay(task.id)
            }
            .tint(.orange)
        }
        .contextMenu {
            Button(task.isMyDay ? "Убрать из «Моего дня»" : "Добавить в «Мой день»", systemImage: "sun.max") {
                store.toggleMyDay(task.id)
            }
            Button(task.isImportant ? "Снять важность" : "Отметить важным", systemImage: "star") {
                store.toggleImportant(task.id)
            }
            Menu("Переместить", systemImage: "arrow.right.square") {
                Button(Store.inboxName) { store.moveTask(task.id, toList: Store.inboxID) }
                ForEach(store.lists) { list in
                    Button(list.title) { store.moveTask(task.id, toList: list.id) }
                }
            }
            Button("Удалить", systemImage: "trash", role: .destructive) { store.deleteTask(task.id) }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        var showsList = true
        if let scope {
            if case .inbox = scope { showsList = false }
            if case .list = scope { showsList = false }
        }
        if showsList { parts.append(store.listName(task.data.listId)) }
        if task.isMyDay && scope != .myDay { parts.append("Мой день") }
        if let p = store.stepProgress(of: task.id) { parts.append("\(p.done) из \(p.total)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
