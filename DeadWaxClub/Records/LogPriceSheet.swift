import SwiftUI

struct LogPriceSheet: View {
    let record: VinylRecord
    let existing: PriceEntry?

    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    @State private var amount: String = ""
    @State private var currency: String = Preferences.currency
    @State private var shopName: String = ""
    @State private var date: Date = Date()
    @State private var isSaving = false
    @State private var showDeleteConfirm = false

    init(record: VinylRecord, existing: PriceEntry? = nil) {
        self.record = record
        self.existing = existing
    }

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
                if existing != nil {
                    Section {
                        Button("Delete this price", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Log price" : "Edit price")
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
            .alert(
                "Delete this price entry?",
                isPresented: $showDeleteConfirm
            ) {
                Button("Delete", role: .destructive) {
                    Task { await deleteEntry() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes it from the chart and history. Cannot be undone.")
            }
            .onAppear { populate() }
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

    private func populate() {
        guard let existing else { return }
        amount = String(format: "%.2f", Double(existing.priceCents) / 100)
        currency = existing.currency
        shopName = existing.shopName ?? ""
        date = existing.scannedAt
    }

    private func save() async {
        guard let cents = priceCents,
              let ownerID = services.auth.currentUserID?.uuidString.lowercased() else { return }
        isSaving = true
        defer { isSaving = false }

        if let existing {
            let updated = PriceEntry(
                id: existing.id,
                recordID: existing.recordID,
                ownerID: existing.ownerID,
                collectionID: existing.collectionID,
                priceCents: cents,
                currency: currency,
                shopName: shopName.isEmpty ? nil : shopName,
                scannedAt: date,
                createdAt: existing.createdAt
            )
            await services.prices.update(updated)
        } else {
            let entry = PriceEntry(
                id: UUID().uuidString.lowercased(),
                recordID: record.id,
                ownerID: ownerID,
                collectionID: record.collectionID,
                priceCents: cents,
                currency: currency,
                shopName: shopName.isEmpty ? nil : shopName,
                scannedAt: date,
                createdAt: Date()
            )
            await services.prices.add(entry)
        }
        Haptics.success()
        dismiss()
    }

    private func deleteEntry() async {
        guard let existing else { return }
        await services.prices.delete(entryID: existing.id)
        Haptics.success()
        dismiss()
    }

    private static let commonCurrencies = ["GBP", "USD", "EUR", "CAD", "AUD", "JPY"]
}
