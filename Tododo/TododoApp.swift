import SwiftUI

@main
struct TododoApp: App {
    private static let sharedStore = Store()
    @State private var store = TododoApp.sharedStore
    @State private var lock = AppLock()
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
            Group {
                if lock.isLocked {
                    LockView()
                } else {
                    RootView()
                }
            }
            .overlay {
                #if os(iOS)
                if lock.isEnabled && !lock.isLocked && scenePhase != .active {
                    PrivacyCover()
                }
                #endif
            }
            .environment(store)
            .environment(lock)
            .preferredColorScheme(.light)
            .task { await store.runSyncLoop() }
            .task { await lock.unlockOnLaunch() }
            .onOpenURL { url in
                // A connection link (tododo://setup?...) configures sync in one step.
                if Config.applySetup(url.absoluteString) { store.becameActive() }
            }
        }
        .defaultSize(width: 1060, height: 700)
        #if os(macOS)
        // No title bar strip: the window has nothing to show there (window buttons stay).
        .windowStyle(.hiddenTitleBar)
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.becameActive()
                lock.appReturned()
            } else {
                store.resignedActive()
                lock.appLeft(phase)
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
                .environment(lock)
                .preferredColorScheme(.light)
        }
        #endif
    }
}
