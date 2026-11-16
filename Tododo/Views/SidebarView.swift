import SwiftUI

struct SidebarView: View {
    @Environment(Store.self) private var store
    @Binding var selection: Scope?

    @State private var query = RootView.demoScreen == "search" ? "счёт" : ""
    @State private var collapsed: Set<String> = []
    @State private var detail: TaskRef?
    @State private var showSettings = false

    // Name prompts
    @State private var prompt: NamePrompt?
    @State private var promptText = ""

    private enum NamePrompt: Identifiable {
        case newList(groupID: String?)
        case newGroup
        case rename(id: String)

        var id: String {
            switch self {
            case .newList(let g): return "list-\(g ?? "")"
            case .newGroup: return "group"
            case .rename(let id): return "rename-\(id)"
            }
        }

        var title: String {
            switch self {
            case .newList: return "Новый список"
            case .newGroup: return "Новая группа"
            case .rename: return "Переименовать"
            }
        }
    }

    var body: some View {
        List(selection: $selection) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                smartLists
                userLists
            } else {
                searchResults
            }
        }
        .listStyle(.sidebar)
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        #endif
        .navigationTitle("Tododo")
        .searchable(text: $query, prompt: "Поиск")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: syncIcon)
                }
                .accessibilityLabel("Настройки и синхронизация")
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(item: $detail) { TaskDetailView(taskID: $0.id) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert(prompt?.title ?? "", isPresented: promptShown, presenting: prompt) { p in
            TextField("Название", text: $promptText)
            Button("Готово") { finish(p) }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: Sections

    private var smartLists: some View {
        Section {
            SidebarRow(icon: "sun.max", title: "Мой день", count: store.openCount(.myDay))
                .tag(Scope.myDay)
            SidebarRow(icon: "star", title: "Важные", count: store.openCount(.important))
                .tag(Scope.important)
            SidebarRow(icon: "tray", title: Store.inboxName, count: store.openCount(.inbox))
                .tag(Scope.inbox)
        }
    }

    @ViewBuilder
    private var userLists: some View {
        Section {
            ForEach(store.lists(inGroup: nil)) { listRow($0) }
        }
        ForEach(store.groups) { group in
            Section {
                if !collapsed.contains(group.id) {
                    ForEach(store.lists(inGroup: group.id)) { listRow($0) }
                }
            } header: {
                groupHeader(group)
            }
        }
    }

    private var searchResults: some View {
        Section {
            let results = store.search(query)
            if results.isEmpty {
                Text("Ничего не найдено")
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { task in
                TaskRow(task: task, scope: nil) { detail = TaskRef(id: task.id) }
            }
        }
    }

    private func listRow(_ list: Record) -> some View {
        SidebarRow(icon: "list.bullet", title: list.title, count: store.openCount(.list(list.id)))
            .tag(Scope.list(list.id))
            .contextMenu {
                Button("Переименовать", systemImage: "pencil") { ask(.rename(id: list.id), text: list.title) }
                Menu("Группа", systemImage: "folder") {
                    Button("Без группы") { store.setGroup(ofList: list.id, to: nil) }
                    ForEach(store.groups) { g in
                        Button(g.title) { store.setGroup(ofList: list.id, to: g.id) }
                    }
                }
                Button("Удалить список", systemImage: "trash", role: .destructive) { delete(list) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Удалить", systemImage: "trash", role: .destructive) { delete(list) }
            }
    }

    private func groupHeader(_ group: Record) -> some View {
        HStack {
            Button {
                withAnimation { toggle(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Text(group.title)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(collapsed.contains(group.id) ? 0 : 90))
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Menu {
                Button("Новый список в группе", systemImage: "plus") { ask(.newList(groupID: group.id)) }
                Button("Переименовать", systemImage: "pencil") { ask(.rename(id: group.id), text: group.title) }
                Button("Разгруппировать", systemImage: "folder.badge.minus", role: .destructive) { store.deleteGroup(group.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                ask(.newList(groupID: nil))
            } label: {
                Label("Новый список", systemImage: "plus")
                    .fixedSize()
            }
            Spacer()
            Button {
                ask(.newGroup)
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel("Новая группа")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Actions

    private var syncIcon: String {
        switch store.syncStatus {
        case .offline: return "icloud.slash"
        case .notConfigured: return "exclamationmark.icloud"
        default: return store.pendingCount > 0 ? "arrow.triangle.2.circlepath" : "gearshape"
        }
    }

    private var promptShown: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private func ask(_ p: NamePrompt, text: String = "") {
        promptText = text
        prompt = p
    }

    private func finish(_ p: NamePrompt) {
        switch p {
        case .newList(let groupID):
            if let id = store.addList(name: promptText, groupID: groupID) { selection = .list(id) }
        case .newGroup:
            store.addGroup(name: promptText)
        case .rename(let id):
            store.rename(id, to: promptText)
        }
        promptText = ""
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    private func delete(_ list: Record) {
        if selection == .list(list.id) { selection = nil }
        store.deleteList(list.id)
    }
}

struct SidebarRow: View {
    let icon: String
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title)
                .lineLimit(1)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
