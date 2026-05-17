import Foundation

enum AppQuickAction: String {
    case scanBarcode = "scanBarcode"
    case addRecord = "addRecord"
    case logPrice = "logPrice"
}

@MainActor
enum QuickActionRouter {
    private static let pendingActionKey = "dwc.pendingQuickAction"

    private static var isReady = false
    private static var pendingAction: AppQuickAction?

    static func activate() {
        isReady = true
        if let stored = UserDefaults.standard.string(forKey: pendingActionKey),
           let action = AppQuickAction(rawValue: stored) {
            pendingAction = action
            UserDefaults.standard.removeObject(forKey: pendingActionKey)
        }
        flushPendingAction()
    }

    static func handle(_ action: AppQuickAction) {
        guard isReady else {
            pendingAction = action
            UserDefaults.standard.set(action.rawValue, forKey: pendingActionKey)
            return
        }
        route(action)
    }

    private static func flushPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        route(action)
    }

    private static func route(_ action: AppQuickAction) {
        switch action {
        case .scanBarcode:
            NotificationCenter.default.post(
                name: .switchMainTab,
                object: nil,
                userInfo: ["tab": MainTab.scan]
            )
        case .addRecord:
            NotificationCenter.default.post(name: .openAddRecord, object: nil)
        case .logPrice:
            NotificationCenter.default.post(name: .openLogPrice, object: nil)
        }
    }
}
