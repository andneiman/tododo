import SwiftUI

struct RootView: View {
    @State private var selection: Scope? = RootView.initialSelection
    @State private var debugSheet: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
        } detail: {
            if let selection {
                TaskListView(scope: selection)
                    .id(selection)
            } else {
                ContentUnavailableView("Выберите список", systemImage: "checklist")
            }
        }
        #if DEBUG
        .sheet(item: $debugSheet) { name in
            if name == "settings" { SettingsView() } else { TaskDetailView(taskID: "demo-6") }
        }
        .onAppear {
            let screen = RootView.demoScreen
            if screen == "detail" || screen == "settings" { debugSheet = screen }
        }
        #endif
    }

    /// `-demo-screen <name>` opens a given screen with sample data (used for automated screenshots).
    static var demoScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo-screen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var initialSelection: Scope? {
        switch demoScreen {
        case "myday", "detail": return .myDay
        case "list": return .list("demo-2")
        case "empty": return .list("demo-3")
        case "home", "search", "settings": return nil
        default: break
        }
        #if os(macOS)
        return .myDay
        #else
        return nil
        #endif
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}
