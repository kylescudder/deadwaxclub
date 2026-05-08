import SwiftUI

struct RecordsFilterSheet: View {
    @Binding var filter: RecordsFilter
    @Environment(\.dismiss) private var dismiss

    @State private var yearFrom: Int?
    @State private var yearTo: Int?
    @State private var colourwayText = ""
    @State private var hasPriceOnly = false
    @State private var hasNoPriceOnly = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Year") {
                    HStack {
                        Picker("From", selection: $yearFrom) {
                            Text("Any").tag(Int?.none)
                            ForEach(Self.yearOptions, id: \.self) { year in
                                Text(String(year)).tag(Optional(year))
                            }
                        }
                        .pickerStyle(.menu)

                        Spacer()
                        Text("–").foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()

                        Picker("To", selection: $yearTo) {
                            Text("Any").tag(Int?.none)
                            ForEach(Self.yearOptions, id: \.self) { year in
                                Text(String(year)).tag(Optional(year))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                Section("Colour way") {
                    TextField("e.g. Splatter, Coke Bottle", text: $colourwayText)
                }
                Section("Estimated value") {
                    // Mutually exclusive — turning one on turns the other off,
                    // since "with" and "without" can't both be true.
                    Toggle("Only with estimated value", isOn: Binding(
                        get: { hasPriceOnly },
                        set: { newValue in
                            hasPriceOnly = newValue
                            if newValue { hasNoPriceOnly = false }
                        }
                    ))
                    Toggle("Only without estimated value", isOn: Binding(
                        get: { hasNoPriceOnly },
                        set: { newValue in
                            hasNoPriceOnly = newValue
                            if newValue { hasPriceOnly = false }
                        }
                    ))
                }
                Section {
                    Button("Reset", role: .destructive) {
                        yearFrom = nil
                        yearTo = nil
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

    /// Newest year first (vinyl users care about recent reissues more often
    /// than 1920s pressings). Range generous enough to cover anything realistic.
    private static let yearOptions: [Int] = {
        let current = Calendar.current.component(.year, from: Date())
        return Array((1900...(current + 1)).reversed())
    }()

    private func load() {
        if let range = filter.yearRange {
            yearFrom = range.lowerBound == .min ? nil : range.lowerBound
            yearTo = range.upperBound == .max ? nil : range.upperBound
        } else {
            yearFrom = nil
            yearTo = nil
        }
        colourwayText = filter.colourwayContains ?? ""
        hasPriceOnly = filter.hasPriceOnly
        hasNoPriceOnly = filter.hasNoPriceOnly
    }

    private func apply() {
        let range: ClosedRange<Int>?
        switch (yearFrom, yearTo) {
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
