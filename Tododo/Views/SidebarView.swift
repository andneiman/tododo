import SwiftUI

struct SidebarView: View {
    @Environment(Store.self) private var store
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @Binding var selection: Scope?
    let query: String

    @State private var collapsed: Set<String> = []
    @State private var editingID: String?
    @State private var editText = ""
    @FocusState private var editFocused: Bool
    @State private var listToDelete: Record?
    @State private var showSettings = RootView.demoScreen == "settings"
    @State private var searchDetail: String?

    var body: some View {
        List(selection: $selection) {
            #if os(iOS)
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                lists
            } else {
                searchResults
            }
            #else
            lists
            #endif
        }
        .listStyle(.sidebar)
        .onChange(of: editFocused) { _, focused in
            if !focused { commitEdit() }
        }
        .confirmationDialog(
            "Delete “\(listToDelete?.title ?? "")”?",
            isPresented: Binding(get: { listToDelete != nil }, set: { if !$0 { listToDelete = nil } }),
            presenting: listToDelete
        ) { list in
            Button("Delete List", role: .destructive) { delete(list) }
        } message: { list in
            let n = store.taskCount(inList: list.id)
            Text(n == 0 ? "This list is empty." : "\(n == 1 ? "Its task" : "All \(n) of its tasks") will be deleted too. You can restore them from Claude.")
        }
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) { macBottomBar }
        #else
        .navigationTitle("Tododo")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New List", systemImage: "list.bullet") { newList(in: nil) }
                    Button("New Group", systemImage: "folder") { newGroup() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: store.syncNeedsAttention ? store.syncSymbol : "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $searchDetail) { id in
            TaskDetailView(taskID: id) { searchDetail = nil }
        }
        #endif
    }

    // MARK: Sections

    @ViewBuilder
    private var lists: some View {
        Section {
            smartRow(.myDay, "My Day", "sun.max")
            smartRow(.important, "Important", "star")
        }

        // "Tasks" is just the first list: always there, can't be deleted.
        Section("Lists") {
            smartRow(.inbox, Store.inboxName, "list.bullet")
            ForEach(store.lists(inGroup: nil)) { listRow($0) }
        }

        ForEach(store.groups) { group in
            Section(isExpanded: expanded(group.id)) {
                ForEach(store.lists(inGroup: group.id)) { listRow($0) }
            } header: {
                groupHeader(group)
            }
        }
    }

    #if os(iOS)
    private var searchResults: some View {
        Section {
            let results = store.search(query)
            if results.isEmpty {
                Text("No Results")
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { task in
                TaskRow(task: task, scope: nil)
                    .onTapGesture { searchDetail = task.id }
            }
        }
    }
    #endif

    private func smartRow(_ scope: Scope, _ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .badge(store.openCount(scope))
            .tag(scope)
    }

    @ViewBuilder
    private func listRow(_ list: Record) -> some View {
        Group {
            if editingID == list.id {
                Label {
                    TextField("List Name", text: $editText, prompt: Text("Untitled List"))
                        .textFieldStyle(.plain)
                        .focused($editFocused)
                        .onSubmit { editFocused = false }
                } icon: {
                    Image(systemName: "list.bullet")
                }
            } else {
                Label(list.title, systemImage: "list.bullet")
                    .badge(store.openCount(.list(list.id)))
            }
        }
        .tag(Scope.list(list.id))
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startEditing(list.id, text: list.title) }
            Menu("Move to Group", systemImage: "folder") {
                Button("None") { store.setGroup(ofList: list.id, to: nil) }
                if !store.groups.isEmpty { Divider() }
                ForEach(store.groups) { g in
                    Button(g.title) { store.setGroup(ofList: list.id, to: g.id) }
                }
            }
            Divider()
            Button("Delete List…", systemImage: "trash", role: .destructive) { listToDelete = list }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { listToDelete = list }
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: Record) -> some View {
        Group {
            if editingID == group.id {
                TextField("Group Name", text: $editText, prompt: Text("Untitled Group"))
                    .textFieldStyle(.plain)
                    .focused($editFocused)
                    .onSubmit { editFocused = false }
            } else {
                Text(group.title)
            }
        }
        .contextMenu {
            Button("New List in Group", systemImage: "plus") { newList(in: group.id) }
            Button("Rename Group", systemImage: "pencil") { startEditing(group.id, text: group.title) }
            Divider()
            Button("Ungroup", systemImage: "folder.badge.minus") { store.deleteGroup(group.id) }
        }
    }

    #if os(macOS)
    private var macBottomBar: some View {
        HStack(spacing: 14) {
            Button { newList(in: nil) } label: {
                Label("New List", systemImage: "plus")
            }
            Spacer()
            Button { openSettings() } label: {
                Image(systemName: store.syncSymbol)
                    .foregroundStyle(store.syncNeedsAttention ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            .help(store.syncText)
            Button { newGroup() } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Group")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    #endif

    // MARK: Actions

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { open in if open { collapsed.remove(id) } else { collapsed.insert(id) } }
        )
    }

    private func newList(in groupID: String?) {
        guard let id = store.addList(name: "Untitled List", groupID: groupID) else { return }
        if let groupID { collapsed.remove(groupID) }
        selection = .list(id)
        startEditing(id, text: "")
    }

    private func newGroup() {
        guard let id = store.addGroup(name: "Untitled Group") else { return }
        startEditing(id, text: "")
    }

    private func startEditing(_ id: String, text: String) {
        editText = text
        editingID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { editFocused = true }
    }

    private func commitEdit() {
        guard let id = editingID else { return }
        editingID = nil
        store.rename(id, to: editText)
        editText = ""
    }

    private func delete(_ list: Record) {
        if selection == .list(list.id) { selection = .inbox }
        store.deleteList(list.id)
    }
}
