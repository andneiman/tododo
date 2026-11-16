import Foundation
import Observation
import SwiftUI

/// The whole app state lives in memory and is mirrored to one JSON file.
/// Every screen reads from here, so the UI never waits on disk or network.
@MainActor
@Observable
final class Store {
    static let inboxID = "00000000-0000-0000-0000-000000000001"
    static let inboxName = "Задачи"

    private(set) var records: [String: Record] = [:]
    private(set) var syncStatus: SyncStatus = .idle
    /// Bumps when a task is completed, to drive haptics.
    private(set) var doneTick = 0

    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var epoch: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            seedDemo()
            return
        }
        #endif
        load()
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
            make(&d)
            let id = "demo-\(Int(n))"
            records[id] = Record(id: id, kind: kind, data: d, updatedAt: n, deleted: false)
            return id
        }
        let group = add(.group) { $0.name = "Проекты" }
        let work = add(.list) { $0.name = "Quicks"; $0.groupId = group }
        _ = add(.list) { $0.name = "Senses"; $0.groupId = group }
        _ = add(.list) { $0.name = "Покупки" }
        _ = add(.task) { $0.title = "Сделать"; $0.isSection = true; $0.myDay = true }
        let call = add(.task) { $0.title = "Созвон с командой по релизу"; $0.myDay = true; $0.important = true; $0.listId = work }
        _ = add(.step) { $0.title = "Собрать повестку"; $0.taskId = call; $0.completed = true }
        _ = add(.step) { $0.title = "Отправить инвайты"; $0.taskId = call }
        _ = add(.task) { $0.title = "Оплатить счёт за отопление"; $0.myDay = true }
        _ = add(.task) { $0.title = "Ответить на письма"; $0.myDay = true }
        _ = add(.task) { $0.title = "Подумать"; $0.isSection = true; $0.myDay = true }
        _ = add(.task) { $0.title = "Идея для онбординга"; $0.myDay = true; $0.listId = work }
        _ = add(.task) { $0.title = "Куда поехать в январе"; $0.myDay = true }
        _ = add(.task) { $0.title = "Заказать воду"; $0.myDay = true; $0.completed = true; $0.completedAt = Self.now }
        _ = add(.task) { $0.title = "Молоко"; $0.listId = "demo-4" }
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
        case .myDay: return "Мой день"
        case .important: return "Важные"
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

    private static var now: Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    private func commit(_ record: Record) {
        var r = record
        r.updatedAt = max(Self.now, (records[r.id]?.updatedAt ?? 0) + 1)
        records[r.id] = r
        dirty.insert(r.id)
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
        commit(r)
    }

    private func create(_ kind: Kind, _ data: Payload) -> String {
        let id = UUID().uuidString.lowercased()
        commit(Record(id: id, kind: kind, data: data, updatedAt: 0, deleted: false))
        return id
    }

    private func nextPosition(_ items: [Record], myDay: Bool = false) -> Double {
        let top = items.map { myDay ? ($0.data.myDayPosition ?? $0.data.position ?? 0) : ($0.data.position ?? 0) }.max()
        return (top ?? 0) + 1
    }

    /// Adds a task to the bottom of the scope. A title starting with "#" becomes a section divider.
    func addTask(_ raw: String, in scope: Scope) {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var isSection = false
        if title.hasPrefix("#") {
            title = String(title.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            isSection = true
        }
        guard !title.isEmpty else { return }

        var listID = Self.inboxID
        if case .list(let id) = scope { listID = id }
        let all = live(.task)

        var d = Payload()
        d.title = title
        d.listId = listID
        d.createdAt = Self.now
        d.position = nextPosition(all.filter { self.listID(of: $0) == listID })
        if isSection { d.isSection = true }
        if scope == .myDay {
            d.myDay = true
            d.myDayPosition = nextPosition(all.filter(\.isMyDay), myDay: true)
        }
        if scope == .important && !isSection { d.important = true }
        _ = create(.task, d)
    }

    func toggleDone(_ id: String) {
        guard let r = record(id) else { return }
        let done = !r.isDone
        update(id) {
            $0.completed = done ? true : nil
            $0.completedAt = done ? Self.now : nil
        }
        if done { doneTick += 1 }
    }

    func toggleImportant(_ id: String) {
        update(id) { $0.important = $0.important == true ? nil : true }
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
        _ = create(.step, d)
    }

    func toggleStep(_ id: String) {
        update(id) { $0.completed = $0.completed == true ? nil : true }
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

    func addGroup(name raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var d = Payload()
        d.name = name
        d.position = nextPosition(live(.group))
        _ = create(.group, d)
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
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tododo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        records = Dictionary(snap.records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        dirty = Set(snap.dirty)
        cursor = snap.cursor
        epoch = snap.epoch
    }

    private func snapshotData() -> Data? {
        try? JSONEncoder().encode(Snapshot(records: Array(records.values), dirty: Array(dirty), cursor: cursor, epoch: epoch))
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
        let changes: [Record]
    }

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Foreground loop: picks up changes made elsewhere (Claude, another device).
    func runSyncLoop() async {
        while !Task.isCancelled {
            await sync()
            try? await Task.sleep(for: .seconds(15))
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
            } catch {
                syncStatus = .offline
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
            if let local = next[change.id], dirty.contains(change.id), local.updatedAt > change.updatedAt { continue }
            dirty.remove(change.id)
            next[change.id] = change.deleted ? nil : change
        }
        if let old = epoch, old != response.epoch {
            // Server storage was recreated: send everything we have.
            dirty = Set(next.keys)
        }
        epoch = response.epoch
        cursor = response.cursor
        if next != records { records = next }
        scheduleSave()
    }
}
