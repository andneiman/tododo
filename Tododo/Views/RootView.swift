import SwiftUI

struct RootView: View {
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var selection: Scope? = RootView.initialSelection
    @State private var query = RootView.demoScreen == "search" ? "bill" : ""

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, query: query)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .searchable(text: $query, prompt: "Search")
        .onChange(of: selection) { _, _ in query = "" }
        #if os(macOS)
        .onAppear {
            if RootView.demoScreen == "settings" { openSettings() }
        }
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        #if os(macOS)
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsView(query: query)
        } else if let selection {
            TaskListView(scope: selection)
                .id(selection)
        } else {
            ContentUnavailableView("No List Selected", systemImage: "checklist")
        }
        #else
        if let selection {
            TaskListView(scope: selection)
                .id(selection)
        } else {
            ContentUnavailableView("No List Selected", systemImage: "checklist")
        }
        #endif
    }

    /// `-demo YES -demoScreen <name>` opens a given screen with sample data (used for automated screenshots).
    static var demoScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var initialSelection: Scope? {
        switch demoScreen {
        case "myday", "detail": return .myDay
        case "list": return .list("demo-2")
        case "empty": return .list("demo-3")
        case "home", "search": return nil
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
