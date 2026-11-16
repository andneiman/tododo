import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Состояние", value: statusText)
                    Button("Синхронизировать сейчас") {
                        Task { await store.sync() }
                    }
                } header: {
                    Text("Синхронизация")
                } footer: {
                    Text("Приложение полностью работает офлайн. Изменения отправляются на сервер, как только появляется сеть.")
                }

                Section("Сервер") {
                    TextField("Адрес сервера", text: $url)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    #endif
                    SecureField("Токен приложения", text: $token)
                    Button("Сохранить") {
                        Config.save(url: url, token: token)
                        Task { await store.sync() }
                    }
                    .disabled(url.isEmpty || token.isEmpty)
                }
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .onAppear {
            if let c = Config.current {
                url = c.url.absoluteString
                token = c.token
            }
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
