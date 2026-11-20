import SwiftUI

@main
struct TododoApp: App {
    private static let sharedStore = Store()
    @State private var store = TododoApp.sharedStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if E2E.isActive {
            let store = TododoApp.sharedStore
            Task { @MainActor in await E2E.run(store) }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.light)
                .task { await store.runSyncLoop() }
                .onOpenURL { url in
                    // A connection link (tododo://setup?...) configures sync in one step.
                    if Config.applySetup(url.absoluteString) { store.becameActive() }
                }
        }
        .defaultSize(width: 1060, height: 700)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.becameActive()
            } else {
                store.resignedActive()
            }
        }
        #if os(macOS)
        .commands {
            // ⌘N adds a task (see the toolbar), not a second window.
            CommandGroup(replacing: .newItem) {}
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(store)
                .preferredColorScheme(.light)
        }
        #endif
    }
}
