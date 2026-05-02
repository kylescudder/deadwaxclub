import SwiftUI

struct RecordsFilterSheet: View {
    @Binding var filter: RecordsFilter
    @Environment(\.dismiss) private var dismiss

    @State private var yearFromText = ""
    @State private var yearToText = ""
    @State private var colourwayText = ""
    @State private var hasPriceOnly = false
    @State private var hasNoPriceOnly = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Year") {
                    HStack {
                        TextField("From", text: $yearFromText)
                            .keyboardType(.numberPad)
                        Text("–").foregroundStyle(Theme.Colors.textSecondary)
                        TextField("To", text: $yearToText)
                            .keyboardType(.numberPad)
                    }
                }
                Section("Colour way") {
                    TextField("e.g. Splatter, Coke Bottle", text: $colourwayText)
                }
                Section("Price") {
                    Toggle("Only with estimated value", isOn: $hasPriceOnly)
                    Toggle("Only without price", isOn: $hasNoPriceOnly)
                }
                Section {
                    Button("Reset", role: .destructive) {
                        yearFromText = ""
                        yearToText = ""
                        colourwayText = ""
                        hasPriceOnly = false
                        hasNoPriceOnly = false
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply(); dismiss() }
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        yearFromText = filter.yearRange.map { "\($0.lowerBound)" } ?? ""
        yearToText = filter.yearRange.map { "\($0.upperBound)" } ?? ""
        colourwayText = filter.colourwayContains ?? ""
        hasPriceOnly = filter.hasPriceOnly
        hasNoPriceOnly = filter.hasNoPriceOnly
    }

    private func apply() {
        let from = Int(yearFromText)
        let to = Int(yearToText)
        let range: ClosedRange<Int>?
        switch (from, to) {
        case let (.some(a), .some(b)): range = min(a, b)...max(a, b)
        case let (.some(a), nil):      range = a...Int.max
        case let (nil, .some(b)):      range = Int.min...b
        default:                       range = nil
        }
        filter = RecordsFilter(
            yearRange: range,
            colourwayContains: colourwayText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : colourwayText,
            hasPriceOnly: hasPriceOnly,
            hasNoPriceOnly: hasNoPriceOnly
        )
        Haptics.tap()
    }
}
