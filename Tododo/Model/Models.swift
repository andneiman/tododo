import Foundation

/// Everything the app stores is a `Record`: one flat, syncable shape for groups, lists, tasks and steps.
enum Kind: String, Codable {
    case group, list, task, step
}

struct Payload: Codable, Equatable {
    var name: String?          // group, list
    var title: String?         // task, step
    var groupId: String?       // list -> group
    var listId: String?        // task -> list
    var taskId: String?        // step -> task
    var position: Double?
    var completed: Bool?
    var completedAt: Double?   // ms since 1970
    var important: Bool?
    var myDay: Bool?
    var myDayPosition: Double?
    var isSection: Bool?       // task that is a visual divider ("To Do", "Think About")
    var createdAt: Double?
}

extension Payload {
    /// Names (as in JSON) of the fields whose values differ from `old`.
    func changedFields(from old: Payload) -> [String] {
        var out: [String] = []
        if name != old.name { out.append("name") }
        if title != old.title { out.append("title") }
        if groupId != old.groupId { out.append("groupId") }
        if listId != old.listId { out.append("listId") }
        if taskId != old.taskId { out.append("taskId") }
        if position != old.position { out.append("position") }
        if completed != old.completed { out.append("completed") }
        if completedAt != old.completedAt { out.append("completedAt") }
        if important != old.important { out.append("important") }
        if myDay != old.myDay { out.append("myDay") }
        if myDayPosition != old.myDayPosition { out.append("myDayPosition") }
        if isSection != old.isSection { out.append("isSection") }
        if createdAt != old.createdAt { out.append("createdAt") }
        return out
    }
}

struct Record: Codable, Equatable, Identifiable {
    var id: String
    var kind: Kind
    var data: Payload
    var updatedAt: Double      // ms since 1970
    var deleted: Bool
    /// When each data field was last changed. The server merges records field by field,
    /// so edits made on two devices to different fields of one task both survive.
    var ft: [String: Double]? = nil

    var title: String { data.title ?? data.name ?? "" }
    var isDone: Bool { data.completed == true }
    var isImportant: Bool { data.important == true }
    var isMyDay: Bool { data.myDay == true }
    var isSection: Bool { data.isSection == true }
}

/// What a task screen shows.
enum Scope: Hashable {
    case myDay
    case important
    case inbox
    case list(String)
}

struct TaskRef: Identifiable, Hashable {
    let id: String
}

enum SyncStatus: Equatable {
    case notConfigured
    case idle
    case syncing
    case ok(Date)
    case offline
}
