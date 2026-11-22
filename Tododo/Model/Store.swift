import Foundation
import Network
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The whole app state lives in memory and is mirrored to one JSON file.
/// Every screen reads from here, so the UI never waits on disk or network.
@MainActor
@Observable
final class Store {
    static let inboxID = "00000000-0000-0000-0000-000000000001"
    static let inboxName = "Tasks"

    private(set) var records: [String: Record] = [:]
    private(set) var syncStatus: SyncStatus = .idle
    /// Bumps when a task is completed, to drive haptics.
    private(set) var doneTick = 0
    /// Changes made on this device that the server has not confirmed yet.
    private(set) var pendingCount = 0
    /// UI only: a task that is being lifted to the top after starring. Its row is
    /// hidden while the list rearranges, so it never slides over other rows.
    var liftingID: String?

    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var epoch: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var syncAgain = false
    /// Server clock minus device clock (ms): keeps timestamps comparable across devices.
    @ObservationIgnored private var clockOffset: Double = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: Double = 3
    @ObservationIgnored private var fastPollUntil = Date.distantPast
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var isFrontmost = true
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
    /// Scripted test mode: nothing syncs on its own, only when the script says so.
    @ObservationIgnored private let isManual = ProcessInfo.processInfo.arguments.contains("-e2e")

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            seedDemo()
            return
        }
        #endif
        load()
        pendingCount = dirty.count
        startNetworkMonitor()
    }

    #if DEBUG
    /// In-memory sample data for screenshots and UI checks (`-demo` launch argument). Nothing is saved or synced.
    private func seedDemo() {
        var n = 0.0
        func add(_ kind: Kind, _ make: (inout Payload) -> Void) -> String {
            n += 1
            var d = Payload()
            d.position = n
            d.myDayPosition = n
            d.createdAt = now - 86_400_000 * 3
            make(&d)
            let id = "demo-\(Int(n))"
            records[id] = Record(id: id, kind: kind, data: d, updatedAt: n, deleted: false)
            return id
        }
        let group = add(.group) { $0.name = "Projects" }
        let work = add(.list) { $0.name = "Launch"; $0.groupId = group }
        _ = add(.list) { $0.name = "Personal"; $0.groupId = group }
        _ = add(.list) { $0.name = "Groceries" }
        _ = add(.task) { $0.title = "To Do"; $0.isSection = true; $0.myDay = true }
        let call = add(.task) { $0.title = "Call the team about the release"; $0.myDay = true; $0.important = true; $0.listId = work }
        _ = add(.step) { $0.title = "Prepare the agenda"; $0.taskId = call; $0.completed = true }
        _ = add(.step) { $0.title = "Send invites"; $0.taskId = call; $0.important = true }
        _ = add(.step) { $0.title = "Book a room"; $0.taskId = call }
        _ = add(.task) { $0.title = "Pay the heating bill"; $0.myDay = true }
        _ = add(.task) { $0.title = "Reply to emails"; $0.myDay = true }
        _ = add(.task) { $0.title = "Think About"; $0.isSection = true; $0.myDay = true; $0.color = "indigo" }
        _ = add(.task) { $0.title = "Onboarding idea"; $0.myDay = true; $0.listId = work }
        _ = add(.task) { $0.title = "Where to go in January"; $0.myDay = true }
        _ = add(.task) { $0.title = "Order water"; $0.myDay = true; $0.completed = true; $0.completedAt = now }
        _ = add(.task) { $0.title = "Oat milk"; $0.listId = "demo-4" }
        _ = add(.task) { $0.title = "Release"; $0.isSection = true; $0.listId = work }
        _ = add(.task) { $0.title = "Check a long task title that does not fit on one line and should wrap neatly onto the next one"; $0.listId = work; $0.important = true }
        _ = add(.task) { $0.title = "Update App Store screenshots"; $0.listId = work; $0.completed = true; $0.completedAt = now }
    }

    func debugFind(_ title: String, kind: Kind) -> String? {
        records.values.first { $0.kind == kind && !$0.deleted && $0.title == title }?.id
    }

    /// Stable, human-readable state: one line per list, task and step.
    func debugDump() -> [String] {
        var lines: [String] = []
        for l in lists { lines.append("list|\(l.title)") }
        let tasks = records.values.filter { $0.kind == .task && !$0.deleted }.sorted { $0.title < $1.title }
        for t in tasks {
            let flags = [t.isSection ? "section" : nil, t.isDone ? "done" : nil, t.isImportant ? "important" : nil, t.isMyDay ? "myday" : nil]
                .compactMap { $0 }.joined(separator: ",")
            let s = steps(of: t.id).map { $0.title + ($0.isDone ? "(done)" : "") }.joined(separator: ",")
            lines.append("task|\(t.title)|\(listName(listID(of: t)))|\(flags)|\(s)")
        }
        lines.append("pending|\(dirty.count)")
        return lines
    }
    #endif

    // MARK: - Queries

    func record(_ id: String) -> Record? {
        guard let r = records[id], !r.deleted else { return nil }
        return r
    }

    private func live(_ kind: Kind) -> [Record] {
        records.values.filter { $0.kind == kind && !$0.deleted }
    }

    nonisolated private static func byPosition(_ a: Record, _ b: Record) -> Bool {
        let x = a.data.position ?? 0, y = b.data.position ?? 0
        return x == y ? a.id < b.id : x < y
    }

    nonisolated private static func byMyDay(_ a: Record, _ b: Record) -> Bool {
        let x = a.data.myDayPosition ?? a.data.position ?? 0
        let y = b.data.myDayPosition ?? b.data.position ?? 0
        return x == y ? a.id < b.id : x < y
    }

    var groups: [Record] {
        live(.group).sorted(by: Self.byPosition)
    }

    var lists: [Record] {
        live(.list).sorted(by: Self.byPosition)
    }

    /// Lists in a group; `nil` returns lists without a (live) group.
    func lists(inGroup groupID: String?) -> [Record] {
        let groupIDs = Set(live(.group).map(\.id))
        return lists.filter { list in
            let g = list.data.groupId.flatMap { groupIDs.contains($0) ? $0 : nil }
            return g == groupID
        }
    }

    func listName(_ id: String?) -> String {
        guard let id, id != Self.inboxID, let l = record(id) else { return Self.inboxName }
        return l.title
    }

    func title(of scope: Scope) -> String {
        switch scope {
        case .myDay: return "My Day"
        case .important: return "Important"
        case .inbox: return Self.inboxName
        case .list(let id): return listName(id)
        }
    }

    private func listID(of task: Record) -> String {
        guard let id = task.data.listId, id != Self.inboxID, record(id) != nil else { return Self.inboxID }
        return id
    }

    private func belongs(_ t: Record, to scope: Scope) -> Bool {
        switch scope {
        case .myDay: return t.isMyDay
        case .important: return t.isImportant && !t.isSection
        case .inbox: return listID(of: t) == Self.inboxID
        case .list(let id): return listID(of: t) == id
        }
    }

    /// Open items in display order (with section dividers) and completed tasks, newest first.
    /// My Day never resets: open tasks stay until done; only today's completed ones are shown.
    func tasks(in scope: Scope) -> (open: [Record], done: [Record]) {
        let all = live(.task).filter { belongs($0, to: scope) }
        var open = all.filter { !$0.isDone }
        switch scope {
        case .myDay:
            open.sort(by: Self.byMyDay)
        case .important:
            open.sort { a, b in
                let la = listName(listID(of: a)), lb = listName(listID(of: b))
                return la == lb ? Self.byPosition(a, b) : la < lb
            }
        default:
            open.sort(by: Self.byPosition)
        }
        var done = all.filter { $0.isDone && !$0.isSection }
        if scope == .myDay {
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
            done = done.filter { ($0.data.completedAt ?? 0) >= startOfDay }
        }
        done.sort { ($0.data.completedAt ?? 0) > ($1.data.completedAt ?? 0) }
        return (open, done)
    }

    func openCount(_ scope: Scope) -> Int {
        live(.task).reduce(0) { $0 + (belongs($1, to: scope) && !$1.isDone && !$1.isSection ? 1 : 0) }
    }

    func steps(of taskID: String) -> [Record] {
        live(.step).filter { $0.data.taskId == taskID }.sorted(by: Self.byPosition)
    }

    /// All tasks in a list, open and completed (sections excluded).
    func taskCount(inList id: String) -> Int {
        live(.task).filter { $0.data.listId == id && !$0.isSection }.count
    }

    func stepProgress(of taskID: String) -> (done: Int, total: Int)? {
        let s = live(.step).filter { $0.data.taskId == taskID }
        return s.isEmpty ? nil : (s.filter(\.isDone).count, s.count)
    }

    func search(_ query: String) -> [Record] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let stepHits = Set(live(.step).filter { $0.title.localizedCaseInsensitiveContains(q) }.compactMap(\.data.taskId))
        return live(.task)
            .filter { !$0.isSection && ($0.title.localizedCaseInsensitiveContains(q) || stepHits.contains($0.id)) }
            .sorted { a, b in a.isDone == b.isDone ? (a.data.createdAt ?? 0) > (b.data.createdAt ?? 0) : !a.isDone }
    }

    // MARK: - Mutations

    private var now: Double { (Date().timeIntervalSince1970 * 1000 + clockOffset).rounded() }

    private func commit(_ record: Record) {
        var r = record
        let old = records[r.id]
        let stamp = max(now, (old?.updatedAt ?? 0) + 1)
        var ft = old?.ft ?? [:]
        for field in r.data.changedFields(from: old?.data ?? Payload()) { ft[field] = stamp }
        r.ft = ft
        r.updatedAt = stamp
        records[r.id] = r
        dirty.insert(r.id)
        pendingCount = dirty.count
        fastPollUntil = Date().addingTimeInterval(90)
        lastActivity = Date()
        scheduleSave()
        scheduleSync()
    }

    private func update(_ id: String, _ change: (inout Payload) -> Void) {
        guard var r = record(id) else { return }
        change(&r.data)
        commit(r)
    }

    private func remove(_ id: String) {
        guard var r = record(id) else { return }
        r.deleted = true
        if r.kind == .task || r.kind == .step { r.data.deletedAt = now }
        commit(r)
    }

    private func create(_ kind: Kind, _ data: Payload) -> String {
        let id = UUID().uuidString.lowercased()
        commit(Record(id: id, kind: kind, data: data, updatedAt: 0, deleted: false))
        return id
    }

    /// Position above everything in `items` (new tasks go to the top).
    private func topPosition(_ items: [Record], myDay: Bool = false) -> Double {
        let low = items.map { myDay ? ($0.data.myDayPosition ?? $0.data.position ?? 0) : ($0.data.position ?? 0) }.min()
        return (low ?? 1) - 1
    }

    private func nextPosition(_ items: [Record], myDay: Bool = false) -> Double {
        let top = items.map { myDay ? ($0.data.myDayPosition ?? $0.data.position ?? 0) : ($0.data.position ?? 0) }.max()
        return (top ?? 0) + 1
    }

    /// Adds a task to the scope (top on iPhone, bottom on the Mac). A title starting with "#" becomes a section divider.
    @discardableResult
    func addTask(_ raw: String, in scope: Scope) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var isSection = false
        if title.hasPrefix("#") {
            title = String(title.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            isSection = true
        }
        guard !title.isEmpty else { return nil }

        var listID = Self.inboxID
        if case .list(let id) = scope { listID = id }
        let all = live(.task)

        var d = Payload()
        d.title = title
        d.listId = listID
        d.createdAt = now
        // iPhone adds to the top; the Mac adds to the bottom, next to its add field.
        #if os(iOS)
        d.position = topPosition(all.filter { self.listID(of: $0) == listID })
        #else
        d.position = nextPosition(all.filter { self.listID(of: $0) == listID })
        #endif
        if isSection { d.isSection = true }
        if scope == .myDay {
            d.myDay = true
            #if os(iOS)
            d.myDayPosition = topPosition(all.filter(\.isMyDay), myDay: true)
            #else
            d.myDayPosition = nextPosition(all.filter(\.isMyDay), myDay: true)
            #endif
        }
        if scope == .important && !isSection { d.important = true }
        return create(.task, d)
    }

    /// Text color of a section divider; `nil` restores the default gray.
    func setColor(_ id: String, to color: String?) {
        update(id) { $0.color = color }
    }

    func toggleDone(_ id: String) {
        guard let r = record(id) else { return }
        let done = !r.isDone
        update(id) {
            $0.completed = done ? true : nil
            $0.completedAt = done ? now : nil
        }
        if done { doneTick += 1 }
    }

    /// Starring a task also lifts it to the very top of its list (and of My Day, if it is there).
    func toggleImportant(_ id: String) {
        guard let task = record(id) else { return }
        let starring = !task.isImportant
        let others = live(.task).filter { $0.id != id }
        let listTop = topPosition(others.filter { self.listID(of: $0) == self.listID(of: task) })
        let dayTop = topPosition(others.filter(\.isMyDay), myDay: true)
        update(id) {
            $0.important = starring ? true : nil
            guard starring, !task.isDone else { return }
            $0.position = listTop
            if $0.myDay == true { $0.myDayPosition = dayTop }
        }
    }

    func toggleMyDay(_ id: String) {
        let next = nextPosition(live(.task).filter(\.isMyDay), myDay: true)
        update(id) {
            if $0.myDay == true {
                $0.myDay = nil
                $0.myDayPosition = nil
            } else {
                $0.myDay = true
                $0.myDayPosition = next
            }
        }
    }

    /// Renames a task, step, list or group.
    func rename(_ id: String, to raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let r = record(id), r.title != text else { return }
        update(id) {
            if r.kind == .task || r.kind == .step { $0.title = text } else { $0.name = text }
        }
    }

    func deleteTask(_ id: String) {
        steps(of: id).forEach { remove($0.id) }
        remove(id)
    }

    func moveTask(_ id: String, toList listID: String) {
        guard let r = record(id), self.listID(of: r) != listID else { return }
        let next = nextPosition(live(.task).filter { self.listID(of: $0) == listID })
        update(id) {
            $0.listId = listID
            $0.position = next
        }
    }

    /// Drag-to-reorder among open items. Only the moved item gets a new position (between its neighbours).
    func reorder(in scope: Scope, from source: IndexSet, to destination: Int) {
        guard scope != .important else { return }
        let myDay = scope == .myDay
        var items = tasks(in: scope).open
        let movedIDs = source.map { items[$0].id }
        items.move(fromOffsets: source, toOffset: destination)

        func pos(_ r: Record) -> Double { myDay ? (r.data.myDayPosition ?? r.data.position ?? 0) : (r.data.position ?? 0) }
        func set(_ id: String, _ value: Double) {
            update(id) { if myDay { $0.myDayPosition = value } else { $0.position = value } }
        }

        if movedIDs.count == 1, let i = items.firstIndex(where: { $0.id == movedIDs[0] }) {
            let prev = i > 0 ? pos(items[i - 1]) : nil
            let next = i < items.count - 1 ? pos(items[i + 1]) : nil
            let value: Double
            switch (prev, next) {
            case let (p?, n?): value = (p + n) / 2
            case let (p?, nil): value = p + 1
            case let (nil, n?): value = n - 1
            default: value = 1
            }
            let collides = (prev != nil && value <= prev!) || (next != nil && value >= next!)
            if !collides {
                set(movedIDs[0], value)
                return
            }
        }
        for (index, item) in items.enumerated() where pos(item) != Double(index + 1) {
            set(item.id, Double(index + 1))
        }
    }

    // Steps

    func addStep(to taskID: String, title raw: String) {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var d = Payload()
        d.title = title
        d.taskId = taskID
        d.position = nextPosition(steps(of: taskID))
        d.createdAt = now
        _ = create(.step, d)
    }

    /// Starred steps are the ones the user wants in front of them: shown right under the task in lists.
    func toggleStepStar(_ id: String) {
        update(id) { $0.important = $0.important == true ? nil : true }
    }

    func starredSteps(of taskID: String) -> [Record] {
        steps(of: taskID).filter { $0.isImportant && !$0.isDone }
    }

    func toggleStep(_ id: String) {
        let stamp = now
        update(id) {
            let done = $0.completed != true
            $0.completed = done ? true : nil
            $0.completedAt = done ? stamp : nil
        }
    }

    func deleteStep(_ id: String) {
        remove(id)
    }

    // Lists and groups

    @discardableResult
    func addList(name raw: String, groupID: String? = nil) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var d = Payload()
        d.name = name
        d.groupId = groupID
        d.position = nextPosition(live(.list))
        return create(.list, d)
    }

    func deleteList(_ id: String) {
        live(.task).filter { $0.data.listId == id }.forEach { deleteTask($0.id) }
        remove(id)
    }

    func setGroup(ofList id: String, to groupID: String?) {
        update(id) { $0.groupId = groupID }
    }

    @discardableResult
    func addGroup(name raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var d = Payload()
        d.name = name
        d.position = nextPosition(live(.group))
        return create(.group, d)
    }

    /// Removes the group; its lists stay and become ungrouped.
    func deleteGroup(_ id: String) {
        live(.list).filter { $0.data.groupId == id }.forEach { setGroup(ofList: $0.id, to: nil) }
        remove(id)
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var records: [Record]
        var dirty: [String]
        var cursor: Int
        var epoch: String?
        var clockOffset: Double?
    }

    private static var directory: URL {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tododo", isDirectory: true)
        #if DEBUG
        if let custom = ProcessInfo.processInfo.environment["TODODO_DIR"] { dir = URL(fileURLWithPath: custom, isDirectory: true) }
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent("state.json") }

    private static var backupsURL: URL {
        let dir = directory.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func readSnapshot(_ url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Local safety net: one copy of the state file per day, 30 days deep.
    private func backupIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.fileURL.path) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let target = Self.backupsURL.appendingPathComponent("state-\(f.string(from: Date())).json")
        guard !fm.fileExists(atPath: target.path) else { return }
        try? fm.copyItem(at: Self.fileURL, to: target)
        let all = ((try? fm.contentsOfDirectory(at: Self.backupsURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        all.dropFirst(30).forEach { try? fm.removeItem(at: $0) }
    }

    private func load() {
        let fm = FileManager.default
        var loaded = Self.readSnapshot(Self.fileURL)
        if loaded == nil, fm.fileExists(atPath: Self.fileURL.path) {
            // The state file is unreadable: set it aside and fall back to the newest daily copy.
            let aside = Self.directory.appendingPathComponent("state-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: Self.fileURL, to: aside)
        }
        if loaded == nil {
            let copies = ((try? fm.contentsOfDirectory(at: Self.backupsURL, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("state-") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for copy in copies {
                if let snap = Self.readSnapshot(copy) {
                    loaded = snap
                    break
                }
            }
        }
        backupIfNeeded()
        guard let snap = loaded else { return }
        clockOffset = snap.clockOffset ?? 0
        records = Dictionary(snap.records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        dirty = Set(snap.dirty)
        cursor = snap.cursor
        epoch = snap.epoch
    }

    private func snapshotData() -> Data? {
        try? JSONEncoder().encode(Snapshot(records: Array(records.values), dirty: Array(dirty), cursor: cursor, epoch: epoch, clockOffset: clockOffset))
    }

    private func scheduleSave() {
        if isDemo { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let data = self.snapshotData() else { return }
            let url = Self.fileURL
            Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Writes immediately; call when the app leaves the foreground.
    func flush() {
        if isDemo { return }
        saveTask?.cancel()
        if let data = snapshotData() { try? data.write(to: Self.fileURL, options: .atomic) }
        backupIfNeeded()
    }

    // MARK: - Sync

    private struct SyncRequest: Encodable {
        let epoch: String?
        let cursor: Int
        let changes: [Record]
    }

    private struct SyncResponse: Decodable {
        let epoch: String
        let cursor: Int
        let now: Double?
        let changes: [Record]
    }

    /// The moment the network comes back (out of a plane, a tunnel), push and pull right away.
    private func startNetworkMonitor() {
        if isDemo || isManual { return }
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                self?.retryDelay = 3
                await self?.sync()
            }
        }
        monitor.start(queue: DispatchQueue(label: "tododo.network"))
    }

    /// While something is unsent and the server is unreachable, keep trying: 3s, 6s, 12s … up to a minute.
    private func scheduleRetry() {
        if isManual { return }
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Call when the app comes to the front: sync now and poll quickly for a while.
    func becameActive() {
        if isManual { return }
        isFrontmost = true
        lastActivity = Date()
        fastPollUntil = Date().addingTimeInterval(90)
        Task { await sync() }
    }

    /// Call when the app leaves the front: save, and on iOS finish sending pending changes.
    func resignedActive() {
        isFrontmost = false
        flush()
        #if os(iOS)
        guard !dirty.isEmpty, !isDemo else { return }
        final class Box { var id = UIBackgroundTaskIdentifier.invalid }
        let app = UIApplication.shared
        let box = Box()
        box.id = app.beginBackgroundTask(withName: "tododo.sync") {
            app.endBackgroundTask(box.id)
            box.id = .invalid
        }
        Task {
            await self.sync()
            self.flush()
            if box.id != .invalid {
                app.endBackgroundTask(box.id)
                box.id = .invalid
            }
        }
        #endif
    }

    private func scheduleSync() {
        if isManual { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Foreground loop: picks up changes made elsewhere (Claude, another device).
    func runSyncLoop() async {
        if isManual { return }
        while !Task.isCancelled {
            // Not in front (a Mac window in the background): no polling, the next activation syncs at once.
            guard isFrontmost else {
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            await sync()
            // Quick polling right after activity (so the other device shows up within seconds),
            // relaxed when idle, slow when left open and untouched.
            let idle = Date().timeIntervalSince(lastActivity)
            try? await Task.sleep(for: .seconds(Date() < fastPollUntil ? 4 : (idle < 600 ? 20 : 60)))
        }
    }

    func sync() async {
        if isDemo { return }
        guard let config = Config.current else {
            syncStatus = .notConfigured
            return
        }
        if isSyncing {
            syncAgain = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        if case .ok = syncStatus {} else { syncStatus = .syncing }

        var rounds = 0
        repeat {
            syncAgain = false
            rounds += 1
            let pushing = dirty.compactMap { records[$0] }
            do {
                var request = URLRequest(url: config.url.appendingPathComponent("api/sync"))
                request.httpMethod = "POST"
                request.timeoutInterval = 20
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONEncoder().encode(SyncRequest(epoch: epoch, cursor: cursor, changes: pushing))
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let decoded = try JSONDecoder().decode(SyncResponse.self, from: data)
                apply(decoded, pushed: pushing)
                syncStatus = .ok(Date())
                retryDelay = 3
                retryTask?.cancel()
            } catch {
                syncStatus = .offline
                if !dirty.isEmpty { scheduleRetry() }
                return
            }
        } while (syncAgain || !dirty.isEmpty) && rounds < 5
    }

    private func apply(_ response: SyncResponse, pushed: [Record]) {
        var next = records
        // What we sent is now on the server, unless it was edited again while the request was in flight.
        for p in pushed where next[p.id]?.updatedAt == p.updatedAt {
            dirty.remove(p.id)
            if p.deleted { next[p.id] = nil }
        }
        for change in response.changes {
            // Edited here since the last push: keep ours. The next push merges both sides
            // on the server field by field, and the merged version comes back.
            if dirty.contains(change.id) { continue }
            next[change.id] = change.deleted ? nil : change
        }
        if !response.changes.isEmpty { fastPollUntil = Date().addingTimeInterval(90) }
        if let serverNow = response.now {
            let offset = serverNow - Date().timeIntervalSince1970 * 1000
            clockOffset = abs(offset) > 1500 ? offset : 0
        }
        if let old = epoch, old != response.epoch {
            // Server storage was recreated: send everything we have.
            dirty = Set(next.keys)
        }
        epoch = response.epoch
        cursor = response.cursor
        if next != records { records = next }
        pendingCount = dirty.count
        scheduleSave()
    }
}
