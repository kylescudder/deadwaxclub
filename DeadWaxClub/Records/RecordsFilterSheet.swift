import SwiftUI

struct RecordsFilterSheet: View {
    @Binding var filter: RecordsFilter
    var collections: [VinylCollection] = []
    /// Show the owned/wishlist segmented filter. Off by default — the Records
    /// tab already has a status segmented control at the top, so this is only
    /// surfaced from sheets that show records of all statuses (e.g. the
    /// add-to-list picker).
    var showStatusFilter: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var yearFrom: Int?
    @State private var yearTo: Int?
    @State private var colourwayText = ""
    @State private var hasPriceOnly = false
    @State private var hasNoPriceOnly = false
    @State private var statusSelection: StatusSelection = .any
    @State private var selectedCollectionID: String?
    @State private var applyCount = 0

    private enum StatusSelection: String, CaseIterable, Identifiable {
        case any, owned, wishlist
        var id: String { rawValue }

        var label: String {
            switch self {
            case .any:      return "Any"
            case .owned:    return "Owned"
            case .wishlist: return "Wishlist"
            }
        }

        var statuses: Set<RecordStatus> {
            switch self {
            case .any:      return []
            case .owned:    return [.owned]
            case .wishlist: return [.wishlist]
            }
        }

        static func from(_ statuses: Set<RecordStatus>) -> StatusSelection {
            if statuses == [.owned] { return .owned }
            if statuses == [.wishlist] { return .wishlist }
            return .any
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if collections.count > 1 {
                    Section("Collection") {
                        Picker("Collection", selection: $selectedCollectionID) {
                            Text("All my Collections").tag(String?.none)
                            ForEach(collections) { collection in
                                Text(collection.name).tag(Optional(collection.id))
                            }
                        }
                    }
                }
                if showStatusFilter {
                    Section("Status") {
                        Picker("Status", selection: $statusSelection) {
                            ForEach(StatusSelection.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Album year") {
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
                        statusSelection = .any
                        selectedCollectionID = nil
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
        .sensoryFeedback(.impact(weight: .light), trigger: applyCount)
    }

    /// Newest year first. Range generous enough to cover anything realistic.
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
        statusSelection = StatusSelection.from(filter.statuses)
        selectedCollectionID = collections.contains(where: { $0.id == filter.collectionID })
            ? filter.collectionID
            : nil
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
            collectionID: selectedCollectionID,
            yearRange: range,
            colourwayContains: colourwayText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : colourwayText,
            hasPriceOnly: hasPriceOnly,
            hasNoPriceOnly: hasNoPriceOnly,
            statuses: statusSelection.statuses
        )
        applyCount += 1
    }
}
