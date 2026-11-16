import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var setupCode = ""
    @State private var setupFailed = false
    @State private var connectedHost: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Состояние", value: statusText)
                    if store.pendingCount > 0 {
                        LabeledContent("Ждут отправки", value: "\(store.pendingCount)")
                    }
                    Button("Синхронизировать сейчас") {
                        Task { await store.sync() }
                    }
                } header: {
                    Text("Синхронизация")
                } footer: {
                    Text("Приложение полностью работает офлайн. Изменения отправляются на сервер, как только появляется сеть.")
                }

                Section {
                    if let host = connectedHost {
                        LabeledContent("Сервер", value: host)
                    }
                    TextField("Код подключения", text: $setupCode, prompt: Text("Код подключения"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    Button(connectedHost == nil ? "Подключить" : "Подключить заново") {
                        if Config.applySetup(setupCode) {
                            setupCode = ""
                            setupFailed = false
                            connectedHost = Config.current?.url.host
                            Task { await store.sync() }
                        } else {
                            setupFailed = true
                        }
                    }
                    .disabled(setupCode.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Подключение")
                } footer: {
                    Text(setupFailed
                         ? "Не похоже на код подключения. Он начинается с tododo://setup"
                         : "Вставьте код подключения (tododo://setup…) или откройте его как ссылку на этом устройстве.")
                }

                Section {
                    ShareLink(item: Store.fileURL) {
                        Label("Экспортировать все данные", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Резервные копии")
                } footer: {
                    Text("Копия данных сохраняется на устройстве каждый день (30 дней) и на сервере (90 дней). Удалённое можно вернуть через Claude.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .onAppear {
            store.flush()
            connectedHost = Config.current?.url.host
        }
    }

    private var statusText: String {
        switch store.syncStatus {
        case .notConfigured: return "Не настроена"
        case .idle: return "Ожидание"
        case .syncing: return "Синхронизация…"
        case .ok(let date): return "Обновлено в \(date.formatted(date: .omitted, time: .shortened))"
        case .offline: return "Нет связи — работаем офлайн"
        }
    }
}
