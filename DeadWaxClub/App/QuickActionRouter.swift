import Foundation

/// Routes widget, App Intent and Home Screen quick actions into the app.
/// An action that arrives before the UI is ready (for example on a cold
/// launch) is persisted and replayed once `activate()` runs. This file is
/// identical in every app; the actions and where they go live in
/// `AppQuickAction.swift`.
@MainActor
enum QuickActionRouter {
    private static var isReady = false
    private static var pendingAction: AppQuickAction?

    static func activate() {
        isReady = true
        if let stored = UserDefaults.standard.string(forKey: AppQuickAction.pendingStorageKey),
           let action = AppQuickAction(rawValue: stored) {
            pendingAction = action
            UserDefaults.standard.removeObject(forKey: AppQuickAction.pendingStorageKey)
        }
        flushPendingAction()
    }

    static func handle(_ action: AppQuickAction) {
        guard isReady else {
            pendingAction = action
            UserDefaults.standard.set(action.rawValue, forKey: AppQuickAction.pendingStorageKey)
            return
        }
        action.route()
    }

    private static func flushPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        action.route()
    }
}
