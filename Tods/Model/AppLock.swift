import Foundation
import LocalAuthentication
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Keeps the app behind Face ID / Touch ID (falling back to the device passcode or Mac password).
@MainActor
@Observable
final class AppLock {
    enum Delay: Int, CaseIterable, Identifiable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case oneHour = 3600

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .immediately: return "Immediately"
            case .oneMinute: return "After 1 Minute"
            case .fiveMinutes: return "After 5 Minutes"
            case .fifteenMinutes: return "After 15 Minutes"
            case .oneHour: return "After 1 Hour"
            }
        }
    }

    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var delay: Delay
    private(set) var isAuthenticating = false

    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Shows the lock screen for automated screenshots without ever prompting.
    @ObservationIgnored private let isDemoLock = RootView.demoScreen == "lock"

    private static let enabledKey = "lockEnabled"
    private static let delayKey = "lockDelay"

    init() {
        let d = UserDefaults.standard
        let args = ProcessInfo.processInfo.arguments
        let testing = args.contains("-demo") || args.contains("-e2e")
        #if os(macOS)
        let defaultDelay = Delay.fifteenMinutes
        #else
        let defaultDelay = Delay.immediately
        #endif
        let enabled = testing ? false : (d.object(forKey: Self.enabledKey) as? Bool ?? true)
        isEnabled = enabled
        delay = (d.object(forKey: Self.delayKey) as? Int).flatMap(Delay.init(rawValue:)) ?? defaultDelay
        isLocked = (enabled && Self.canAuthenticate) || RootView.demoScreen == "lock"
        observeMacLocking()
    }

    // MARK: Settings

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if !on { isLocked = false }
    }

    func setDelay(_ value: Delay) {
        delay = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.delayKey)
    }

    // MARK: Device

    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    private static var biometry: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return context.biometryType
    }

    var methodName: String {
        switch Self.biometry {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default:
            #if os(macOS)
            return "Password"
            #else
            return "Passcode"
            #endif
        }
    }

    var methodSymbol: String {
        switch Self.biometry {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock"
        }
    }

    // MARK: Locking

    /// The app left the foreground. Ignored while the system's own unlock prompt is on screen.
    func appLeft(_ phase: ScenePhase) {
        guard isEnabled, !isAuthenticating else { return }
        #if os(iOS)
        // Control Center or a notification only make the app inactive; leaving it means background.
        guard phase == .background else { return }
        #endif
        if leftAt == nil { leftAt = Date() }
    }

    /// The app is back in front: lock if it was away long enough, then ask to unlock.
    func appReturned() {
        guard isEnabled, !isAuthenticating else { return }
        if let left = leftAt, Date().timeIntervalSince(left) >= Double(delay.rawValue) {
            isLocked = true
        }
        leftAt = nil
        if isLocked { Task { await unlock() } }
    }

    func unlockOnLaunch() async {
        if isLocked { await unlock() }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating, !isDemoLock else { return }
        guard Self.canAuthenticate else {
            // No passcode on this device: nothing to check against.
            isLocked = false
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your tasks") {
                isLocked = false
                leftAt = nil
            }
        } catch {
            // Cancelled or failed: stay locked; the lock screen offers to try again.
        }
    }

    private func lockNow() {
        guard isEnabled, Self.canAuthenticate else { return }
        isLocked = true
    }

    /// On the Mac, lock together with the screen.
    private func observeMacLocking() {
        #if os(macOS)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lockNow() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lockNow() }
        })
        #endif
    }
}
