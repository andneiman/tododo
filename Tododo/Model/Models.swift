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
    var isSection: Bool?       // task that is a visual divider ("Сделать", "Подумать")
    var createdAt: Double?
}

struct Record: Codable, Equatable, Identifiable {
    var id: String
    var kind: Kind
    var data: Payload
    var updatedAt: Double      // ms since 1970, drives last-write-wins sync
    var deleted: Bool

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
