import SwiftUI

struct TaskListView: View {
    @Environment(Store.self) private var store
    let scope: Scope

    @State private var selectedTask: String? = RootView.demoScreen == "detail" ? "demo-6" : nil
    @State private var showDone = RootView.demoScreen == "list"
    @State private var draft = ""
    @State private var renamingSection: String?
    @State private var sectionText = ""
    @State private var justAdded: String?
    @FocusState private var adding: Bool
    @FocusState private var sectionFocused: Bool

    var body: some View {
        let tasks = store.tasks(in: scope)
        let openCount = tasks.open.filter { !$0.isSection }.count
        let mover: ((IndexSet, Int) -> Void)? = scope == .important
            ? nil
            : { store.reorder(in: scope, from: $0, to: $1) }

        ScrollViewReader { proxy in
        List {
            #if os(macOS)
            ListHeader(title: store.title(of: scope), subtitle: subtitle, count: openCount)
            #endif

            ForEach(tasks.open) { item in
                row(item)
            }
            .onMove(perform: mover)

            if !tasks.done.isEmpty {
                Section {
                    if showDone {
                        ForEach(tasks.done) { item in
                            TaskRow(task: item, scope: scope)
                                .selectable(item.id, selection: $selectedTask)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Completed")
                        Text("\(tasks.done.count)")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(showDone ? "Hide" : "Show") {
                            withAnimation(.snappy) { showDone.toggle() }
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                    }
                    .padding(.top, 10)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        .onExitCommand { selectedTask = nil }
        #else
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 34)
        #endif
        .onChange(of: justAdded) { _, id in
            guard let id else { return }
            withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
        }
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if tasks.open.isEmpty && tasks.done.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: scope == .myDay ? "sun.max" : "checklist")
                } description: {
                    Text(emptyText)
                }
                .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { addBar }
        .softScrollEdges()
        .navigationTitle(store.title(of: scope))
        .hidesToolbarTitle()
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button { adding = true } label: {
                    Label("New Task", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Task (⌘N)")
            }
            #endif
        }
        .sensoryFeedback(.success, trigger: store.doneTick)
        .onChange(of: sectionFocused) { _, focused in
            if !focused { commitSection() }
        }
        .modifier(TaskInspector(selection: $selectedTask))
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: Record) -> some View {
        if item.isSection {
            Group {
                if renamingSection == item.id {
                    TextField("Section Name", text: $sectionText, prompt: Text("Section"))
                        .textFieldStyle(.plain)
                        .focused($sectionFocused)
                        .onSubmit { sectionFocused = false }
                } else {
                    Text(item.title)
                }
            }
            .font(.headline)
            .foregroundStyle(SectionColor(stored: item.data.color).color)
            .padding(.top, 8)
            .padding(.bottom, 0)
            .listRowSeparator(.hidden)
            .contextMenu {
                Picker("Color", selection: Binding(
                    get: { SectionColor(stored: item.data.color) },
                    set: { store.setColor(item.id, to: $0 == .gray ? nil : $0.rawValue) }
                )) {
                    ForEach(SectionColor.allCases) { c in
                        Label(c.name, systemImage: "circle.fill")
                            .tint(c.color)
                            .tag(c)
                    }
                }
                .pickerStyle(.palette)
                Button("Rename Section", systemImage: "pencil") { startRenaming(item) }
                Divider()
                Button("Delete Section", systemImage: "trash", role: .destructive) { store.deleteTask(item.id) }
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { store.deleteTask(item.id) }
            }
        } else {
            TaskRow(task: item, scope: scope)
                .selectable(item.id, selection: $selectedTask)
        }
    }

    // MARK: Add bar

    private var addBar: some View {
        let isSection = draft.hasPrefix("#")
        return HStack(spacing: 10) {
            Image(systemName: isSection ? "number" : "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(isSection ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            TextField("Add a Task", text: $draft, prompt: Text(isSection ? "Section Name" : "Add a Task"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($adding)
                .submitLabel(.done)
                .onSubmit(submit)
            if isSection {
                Text("Section")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCapsule()
        .help("Start with # to add a section divider")
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: Text

    private var subtitle: String? {
        switch scope {
        case .myDay: return Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        default: return nil
        }
    }

    private var emptyTitle: String {
        scope == .myDay ? "Nothing for Today" : "No Tasks"
    }

    private var emptyText: String {
        switch scope {
        case .myDay: return "Tasks you add to My Day stay here until they’re done."
        case .important: return "Star a task to see it here."
        default: return "Add a task below. Start with # to add a section."
        }
    }

    // MARK: Actions

    private func submit() {
        let text = draft
        draft = ""
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let id = withAnimation(.snappy) { store.addTask(text, in: scope) }
        justAdded = id
        // Keep the field active for the next task.
        DispatchQueue.main.async { adding = true }
    }

    private func startRenaming(_ item: Record) {
        sectionText = item.title
        renamingSection = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { sectionFocused = true }
    }

    private func commitSection() {
        guard let id = renamingSection else { return }
        renamingSection = nil
        store.rename(id, to: sectionText)
    }
}
