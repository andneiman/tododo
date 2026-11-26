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
    @State private var editingSection: String? = RootView.demoScreen == "section" ? "demo-12" : nil
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
                .contentShape(Rectangle())
                .onTapGesture { selectedTask = nil }   // click outside the tasks closes the details
            #endif

            ForEach(tasks.open) { item in
                row(item)
            }
            .onMove(perform: mover)

            if !tasks.done.isEmpty {
                Section {
                    if showDone {
                        ForEach(tasks.done) { item in
                            TaskRow(task: item, scope: scope, onEditTitle: { selectedTask = item.id })
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
        #if os(macOS)
        // Completing the open task closes its details.
        .onChange(of: selectedTask.flatMap { store.record($0)?.isDone }) { _, done in
            if done == true { selectedTask = nil }
        }
        #endif
        .onChange(of: store.scrollTarget) { _, id in
            guard let id else { return }
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
            store.scrollTarget = nil
        }
        .onChange(of: justAdded) { _, id in
            guard let id else { return }
            proxy.scrollTo(id, anchor: .top)
        }
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if tasks.open.isEmpty && tasks.done.isEmpty {
                // No picture: the title, then the hint with each sentence on its own line.
                VStack(spacing: 6) {
                    Text(emptyTitle)
                        .font(.headline)
                    Text(emptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { addBar }
        .softScrollEdges()
        .navigationTitle(store.title(of: scope))
        .hidesToolbarTitle()
        #if os(macOS)
        // No toolbar "+" (the add field is right there); ⌘N still jumps to it.
        .background {
            Button("New Task") { adding = true }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        #endif
        .sensoryFeedback(.success, trigger: store.doneTick)
        .onChange(of: sectionFocused) { _, focused in
            if !focused { commitSection() }
        }
        .modifier(TaskInspector(selection: $selectedTask))
        #if os(iOS)
        .sheet(item: Binding(
            get: { editingSection.map(TaskRef.init(id:)) },
            set: { editingSection = $0?.id }
        )) { ref in
            SectionEditor(id: ref.id)
                .presentationDetents([.medium, .large])
        }
        #endif
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
            .padding(.top, sectionTopPadding)
            .padding(.bottom, sectionBottomPadding)
            .listRowSeparator(.hidden)
            #if os(macOS)
            .contextMenu {
                Picker("Color", selection: Binding(
                    get: { SectionColor(stored: item.data.color) },
                    set: { store.setColor(item.id, to: $0 == .black ? nil : $0.rawValue) }
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
                Button("Delete Section", systemImage: "trash", role: .destructive) { withAnimation(.taskLeave) { store.deleteTask(item.id) } }
            }
            #else
            // iPhone: long press is for dragging only; a tap opens the section editor.
            .contentShape(Rectangle())
            .onTapGesture { editingSection = item.id }
            #endif
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { withAnimation(.taskLeave) { store.deleteTask(item.id) } }
            }
        } else {
            TaskRow(task: item, scope: scope, onEditTitle: { selectedTask = item.id })
                .selectable(item.id, selection: $selectedTask)
        }
    }

    // MARK: Add bar

    private var addBar: some View {
        let isSection = draft.hasPrefix("#")
        return HStack(spacing: 10) {
            Image(systemName: isSection ? "number" : "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(isSection ? AnyShapeStyle(.tint) : AnyShapeStyle(Self.plusStyle))
                .frame(width: 18)
            #if os(iOS)
            // Return adds the task and the keyboard stays put (a plain field would drop focus on
            // Return and pop the keyboard down and up again). Return on an empty field closes it.
            TextField("Add a Task", text: $draft, prompt: Text(isSection ? "Section Name" : "Add a Task"), axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($adding)
                .submitLabel(.return)
                .onChange(of: draft) { _, new in
                    guard new.contains("\n") else { return }
                    draft = new.replacingOccurrences(of: "\n", with: "")
                    if draft.trimmingCharacters(in: .whitespaces).isEmpty { adding = false } else { submit() }
                }
            #else
            TextField("Add a Task", text: $draft, prompt: Text(isSection ? "Section Name" : "Add a Task"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($adding)
                .submitLabel(.done)
                .onSubmit(submit)
            #endif
            if isSection {
                Text("Section")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        #if os(iOS)
        .padding(.vertical, 14)
        // Like ChatGPT's field: frosted Liquid Glass (the list shows through, softly), a clear gray rim
        // and a soft shadow, so it stands out from the list instead of melting into it.
        .frostedGlassCapsule()
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.13), lineWidth: 1))
        .shadow(color: .black.opacity(0.09), radius: 12, y: 3)
        #else
        .padding(.vertical, 12)
        .glassCapsule()
        #endif
        .help("Start with # to add a section divider")
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, addBarBottomPadding)
    }

    #if os(iOS)
    static let plusStyle = HierarchicalShapeStyle.primary
    #else
    static let plusStyle = HierarchicalShapeStyle.secondary
    #endif

    /// iPhone: the field sits half its own height (~23 pt) lower, closer to the
    /// home indicator. While typing it keeps its gap above the keyboard.
    private var addBarBottomPadding: CGFloat {
        #if os(iOS)
        adding ? 16 : -7
        #else
        16
        #endif
    }

    // MARK: Layout

    #if os(macOS)
    private let sectionTopPadding: CGFloat = 16
    private let sectionBottomPadding: CGFloat = 2
    #else
    private let sectionTopPadding: CGFloat = 8
    private let sectionBottomPadding: CGFloat = 0
    #endif

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
        default: return "Add a task below.\nStart with # to add a section."
        }
    }

    // MARK: Actions

    private func submit() {
        let text = draft
        draft = ""
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Appears in place at the top, no sliding around.
        let id = store.addTask(text, in: scope)
        justAdded = id
        #if os(macOS)
        // Details were open on another task: show the new one instead.
        if selectedTask != nil, let id, store.record(id)?.isSection != true { selectedTask = id }
        #endif
        // Keep the field active for the next task (the iPhone field never lets go of it).
        #if os(macOS)
        DispatchQueue.main.async { adding = true }
        #endif
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

#if os(iOS)
/// iPhone editor for a section divider: name, color, delete.
private struct SectionEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let color = SectionColor(stored: store.record(id)?.data.color)
        // Laid out like the task details: a grouped form with a title bar and Done.
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "number")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(color.color)
                            .frame(width: 22)
                        TextField("Section Name", text: $name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(color.color)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { dismiss() }
                    }
                    .padding(.vertical, 6)
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 14) {
                        ForEach(SectionColor.allCases) { c in
                            Button {
                                store.setColor(id, to: c == .black ? nil : c.rawValue)
                            } label: {
                                Circle()
                                    .fill(c == .black ? Color.black : c.color)   // true black swatch (the text color softens it in the sheet)
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        if c == color {
                                            Circle().strokeBorder(.white, lineWidth: 3).padding(3)
                                        }
                                    }
                                    .overlay {
                                        if c == color { Circle().strokeBorder(c.color.opacity(0.35), lineWidth: 2).padding(-4) }
                                    }
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.name)
                            .accessibilityAddTraits(c == color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    Button("Delete Section", systemImage: "trash", role: .destructive) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.taskLeave) { store.deleteTask(id) }
                        }
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Section")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { name = store.record(id)?.title ?? "" }
        .onDisappear {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, store.record(id) != nil { store.rename(id, to: t) }
        }
    }
}
#endif
