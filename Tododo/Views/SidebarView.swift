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
        // A centered alert (an anchored dialog popped up in the wrong place on iPhone).
        .alert(
            "Delete “\(listToDelete?.title ?? "")”?",
            isPresented: Binding(get: { listToDelete != nil }, set: { if !$0 { listToDelete = nil } }),
            presenting: listToDelete
        ) { list in
            Button("Delete List", role: .destructive) { delete(list) }
            Button("Cancel", role: .cancel) {}
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
        // Lists and group titles are one list, so a list can be dragged anywhere —
        // up or down, or under another group's title to move it into that group.
        Section("Lists") {
            smartRow(.inbox, Store.inboxName, "list.bullet")
            ForEach(rows) { row in
                switch row {
                case .list(let list): listRow(list)
                case .group(let group): groupTitleRow(group).moveDisabled(true)
                }
            }
            .onMove(perform: moveRows)
        }
    }

    private enum Row: Identifiable {
        case list(Record), group(Record)
        var id: String { switch self { case .list(let r), .group(let r): r.id } }
    }

    /// Ungrouped lists first, then each group's title followed by its lists (hidden while collapsed).
    private var rows: [Row] {
        var out = store.lists(inGroup: nil).map(Row.list)
        for g in store.groups {
            out.append(.group(g))
            if !collapsed.contains(g.id) { out += store.lists(inGroup: g.id).map(Row.list) }
        }
        return out
    }

    private func moveRows(from source: IndexSet, to destination: Int) {
        var items = rows
        items.move(fromOffsets: source, toOffset: destination)
        // Each list belongs to the group whose title is above it; positions follow the new order.
        var group: String?
        var position = 0.0
        for row in items {
            switch row {
            case .group(let g): group = g.id
            case .list(let l):
                position += 1
                if l.data.groupId != group || l.data.position != position {
                    store.placeList(l.id, inGroup: group, at: position)
                }
            }
        }
        // Lists hidden inside collapsed groups keep their order after the visible ones.
        for g in store.groups where collapsed.contains(g.id) {
            for l in store.lists(inGroup: g.id) where !items.contains(where: { $0.id == l.id }) {
                position += 1
                store.placeList(l.id, inGroup: g.id, at: position)
            }
        }
    }

    /// A group's title inside the Lists section: tap to fold or unfold, long press for its menu.
    private func groupTitleRow(_ group: Record) -> some View {
        HStack {
            groupHeader(group)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard editingID != group.id else { return }   // typing the new name, not folding
            withAnimation(.snappy) {
                if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
            }
        }
        .listRowSeparator(.hidden)
        .selectionDisabled()
        // Long press (right-click on the Mac) anywhere on the group's title row.
        .contextMenu {
            Button("Rename Group", systemImage: "pencil") { startEditing(group.id, text: group.title) }
            Button("New List in Group", systemImage: "plus") { newList(in: group.id) }
            Divider()
            Button("Ungroup", systemImage: "folder.badge.minus") { store.deleteGroup(group.id) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Rename", systemImage: "pencil") { startEditing(group.id, text: group.title) }
                .tint(.gray)
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
                Button("Lists") { store.setGroup(ofList: list.id, to: nil) }
                if !store.groups.isEmpty { Divider() }
                ForEach(store.groups) { g in
                    Button(g.title) { store.setGroup(ofList: list.id, to: g.id) }
                }
            }
            Divider()
            Button("Delete List", systemImage: "trash", role: .destructive) { listToDelete = list }
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
        startEditing(id, text: "")   // named in place; stays where you are
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
        // No animation: animating it made the group title below slide over the lists.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { store.deleteList(list.id) }
    }
}
