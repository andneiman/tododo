import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var setupCode = ""
    @State private var setupFailed = false
    @State private var connectedHost: String?

    var body: some View {
        #if os(iOS)
        NavigationStack {
            form
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #else
        form
            .frame(width: 480, height: 430)
        #endif
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Sync Now") {
                        Task { await store.sync() }
                    }
                    .disabled(Config.current == nil)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Status")
                            Text(store.syncText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: store.syncSymbol)
                            .foregroundStyle(store.syncNeedsAttention ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint))
                    }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Tododo works fully offline. Changes upload as soon as you’re back online.")
            }

            Section {
                if let connectedHost {
                    LabeledContent("Server", value: connectedHost)
                }
                HStack {
                    TextField("Connection Code", text: $setupCode, prompt: Text("Paste a connection code"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                        .onSubmit(connect)
                    Button(connectedHost == nil ? "Connect" : "Reconnect", action: connect)
                        .disabled(setupCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(setupFailed
                     ? "That doesn’t look like a connection code. It starts with tododo://setup"
                     : "Open the connection link on this device, or paste it here.")
            }

            Section {
                ShareLink(item: Store.fileURL) {
                    Label("Export Data…", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("A copy is saved on this device every day for 30 days, and on the server for 90 days. Deleted items can be restored from Claude.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.flush()
            connectedHost = Config.current?.url.host
        }
    }

    private func connect() {
        if Config.applySetup(setupCode) {
            setupCode = ""
            setupFailed = false
            connectedHost = Config.current?.url.host
            Task { await store.sync() }
        } else {
            setupFailed = true
        }
    }
}
