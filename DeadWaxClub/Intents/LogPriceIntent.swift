import AppIntents
import Foundation

struct LogPriceIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a vinyl price"
    static let description = IntentDescription(
        "Record a price you saw for a vinyl record so you can track its history."
    )

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$priceMajor) \(\.$currency) for \(\.$record)") {
            \.$shop
        }
    }

    @Parameter(title: "Record")
    var record: VinylRecordEntity

    @Parameter(title: "Price", default: 0)
    var priceMajor: Double

    @Parameter(title: "Currency", default: "GBP")
    var currency: String

    @Parameter(title: "Shop")
    var shop: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await IntentBridge.logPrice(
            recordID: record.id,
            priceMajor: priceMajor,
            currency: currency,
            shop: shop
        )
        let priceString = CurrencyFormatter.formatMajor(priceMajor, code: currency)
        return .result(dialog: "Logged \(priceString) for \(record.title).")
    }
}

struct OpenRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a vinyl record"
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Record")
    var record: VinylRecordEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        if let services = IntentBridge.services {
            let entities = try await IntentBridge.recordsByID([record.id])
            if !entities.isEmpty {
                NotificationCenter.default.post(
                    name: .openRecord, object: nil,
                    userInfo: ["record_id": record.id]
                )
            }
            _ = services
        }
        return .result()
    }
}
