import Foundation

/// Deadwax Club's quick actions for the shared `QuickActionRouter`. Keep
/// widgets, App Intents, raw values and notification names in sync.
enum AppQuickAction: String, CaseIterable {
    case scanBarcode = "scanBarcode"
    case addRecord = "addRecord"
    case logPrice = "logPrice"

    /// Where an action waits until the UI is ready. Keep the key stable.
    static let pendingStorageKey = "dwc.pendingQuickAction"

    @MainActor
    func route() {
        switch self {
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
