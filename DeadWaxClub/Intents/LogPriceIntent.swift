import AppIntents
import Foundation

struct LogPriceIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a vinyl price"
    static let description = IntentDescription(
        "Open Deadwax Club to choose a collection record and log a price."
    )
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.handle(.logPrice)
        return .result()
    }
}

struct ScanBarcodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan a barcode"
    static let description = IntentDescription("Open Deadwax Club ready to scan a record barcode.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.handle(.scanBarcode)
        return .result()
    }
}

struct AddRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a record"
    static let description = IntentDescription("Open Deadwax Club ready to search for and add a record.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionRouter.handle(.addRecord)
        return .result()
    }
}
