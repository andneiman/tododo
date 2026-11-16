import SwiftUI

@main
struct TododoApp: App {
    @State private var store = Store()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.light)
                .task { await store.runSyncLoop() }
        }
        .defaultSize(width: 940, height: 660)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.becameActive()
            } else {
                store.resignedActive()
            }
        }
    }
}
