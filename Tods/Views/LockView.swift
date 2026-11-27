import SwiftUI

/// Shown instead of the app while it is locked.
struct LockView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("Tods Is Locked")
                .font(.title2.weight(.semibold))
            Text("Your tasks are private to you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await lock.unlock() }
            } label: {
                Label("Unlock with \(lock.methodName)", systemImage: lock.methodSymbol)
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .prominentGlassButton()
            .disabled(lock.isAuthenticating)
            .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
    }
}

/// Covers the app in the iPhone app switcher so tasks never show in the snapshot.
struct PrivacyCover: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 30))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.ignoresSafeArea())
    }
}

extension View {
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
