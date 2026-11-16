#if DEBUG
import Foundation

/// Headless scripted mode for automated sync tests (`-e2e`, script in TODODO_SCRIPT).
/// Each run acts as one device: it executes the commands, prints the resulting state and quits.
@MainActor
enum E2E {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-e2e") }

    static func run(_ store: Store) async {
        let script = ProcessInfo.processInfo.environment["TODODO_SCRIPT"] ?? ""
        for raw in script.split(separator: ";") {
            let parts = raw.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let command = parts.first else { continue }
            let arg = parts.count > 1 ? parts[1] : ""
            let pair = arg.components(separatedBy: ">")
            let first = pair[0]
            let second = pair.count > 1 ? pair[1] : ""
            func task() -> String {
                guard let id = store.debugFind(first, kind: .task) else {
                    print("E2E|ERROR no task '\(first)'")
                    exit(2)
                }
                return id
            }
            switch command {
            case "add": store.addTask(arg, in: .inbox)
            case "addmyday": store.addTask(arg, in: .myDay)
            case "rename": store.rename(task(), to: second)
            case "star": store.toggleImportant(task())
            case "done": store.toggleDone(task())
            case "myday": store.toggleMyDay(task())
            case "delete": store.deleteTask(task())
            case "step": store.addStep(to: task(), title: second)
            case "list": store.addList(name: arg)
            case "move":
                if let list = store.debugFind(second, kind: .list) { store.moveTask(task(), toList: list) }
            case "sync": await store.sync()
            case "wait": try? await Task.sleep(for: .milliseconds(Int(arg) ?? 100))
            case "dump": store.debugDump().forEach { print("E2E|\($0)") }
            default: print("E2E|ERROR unknown command '\(command)'")
            }
        }
        store.flush()
        exit(0)
    }
}
#endif
