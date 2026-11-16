import SwiftUI

struct RootView: View {
    @State private var selection: Scope? = ProcessInfo.processInfo.arguments.contains("-demo-myday") ? .myDay : nil

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
