import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var selection: Scope? = RootView.initialSelection
    @State private var query = RootView.demoScreen == "search" ? "bill" : ""
    @State private var askUndo = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, query: query)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            detail
        }
        #if os(macOS)
        // Mac: search sits at the top of the sidebar, aligned with it (like Reminders).
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        #else
        .searchable(text: $query, prompt: "Search")
        #endif
        .onChange(of: selection) { _, _ in query = "" }
        #if os(iOS)
        // Shake to undo, like everywhere on iPhone: asks first, then puts back the last change.
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            if store.canUndo { askUndo = true }
        }
        .alert("Undo the last change?", isPresented: $askUndo) {
            Button("Cancel", role: .cancel) {}
            Button("Undo") { withAnimation(.snappy) { store.undo() } }
        }
        #endif
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
        case "myday", "detail", "section": return .myDay
        case "list": return .list("demo-2")
        case "empty": return .list("demo-3")
        case "home", "search": return nil
        default: break
        }
        // The app always opens on My Day (iPhone: Back leads to the lists).
        return .myDay
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

#if os(iOS)
import UIKit

extension Notification.Name {
    static let deviceDidShake = Notification.Name("TododoDeviceDidShake")
}

extension UIWindow {
    /// iPhone shake gesture → shake to undo.
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
        super.motionEnded(motion, with: event)
    }
}
#endif
