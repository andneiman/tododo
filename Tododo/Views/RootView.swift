import SwiftUI

struct RootView: View {
    #if os(macOS)
    @State private var selection: Scope? = .myDay
    #else
    @State private var selection: Scope? = ProcessInfo.processInfo.arguments.contains("-demo-myday") ? .myDay : nil
    #endif

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            if let selection {
                TaskListView(scope: selection)
                    .id(selection)
            } else {
                ContentUnavailableView("Выберите список", systemImage: "checklist")
            }
        }
    }
}
