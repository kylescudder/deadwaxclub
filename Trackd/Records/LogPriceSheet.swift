import SwiftUI

struct LogPriceSheet: View {
    let record: VinylRecord

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var amount: String = ""
    @State private var currency: String = Locale.current.currency?.identifier ?? "GBP"
    @State private var shopName: String = ""
    @State private var date: Date = Date()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Price") {
                    HStack {
                        TextField("0.00", text: $amount)
                            .keyboardType(.decimalPad)
                        Picker("", selection: $currency) {
                            ForEach(Self.commonCurrencies, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
                Section("Where") {
                    TextField("Shop (optional)", text: $shopName)
                }
                Section("When") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date])
                }
            }
            .navigationTitle("Log price")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!isValid || isSaving)
                }
            }
        }
    }

    private var isValid: Bool {
        priceCents != nil
    }

    private var priceCents: Int? {
        let normalized = amount.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: normalized) else { return nil }
        let cents = NSDecimalNumber(decimal: value * 100).intValue
        return cents >= 0 ? cents : nil
    }

    private func save() async {
        guard let cents = priceCents,
              let ownerID = services.auth.currentUserID?.uuidString else { return }
        isSaving = true
        defer { isSaving = false }

        let entry = PriceEntry(
            id: UUID().uuidString.lowercased(),
            recordID: record.id,
            ownerID: ownerID,
            priceCents: cents,
            currency: currency,
            shopName: shopName.isEmpty ? nil : shopName,
            scannedAt: date,
            createdAt: Date()
        )
        await services.prices.add(entry)
        dismiss()
    }

    private static let commonCurrencies = ["GBP", "USD", "EUR", "CAD", "AUD", "JPY"]
}
