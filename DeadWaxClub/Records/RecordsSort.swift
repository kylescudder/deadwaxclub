import Foundation

enum RecordsSort: String, CaseIterable, Identifiable {
    case recentlyUpdated
    case recentlyAdded
    case artistAZ
    case titleAZ
    case yearNewest
    case yearOldest
    case priceHighest
    case priceLowest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyUpdated: return "Recently updated"
        case .recentlyAdded:   return "Recently added"
        case .artistAZ:        return "Artist (A–Z)"
        case .titleAZ:         return "Title (A–Z)"
        case .yearNewest:      return "Year (newest first)"
        case .yearOldest:      return "Year (oldest first)"
        case .priceHighest:    return "Estimated value (high → low)"
        case .priceLowest:     return "Estimated value (low → high)"
        }
    }
}

struct RecordsFilter: Equatable {
    var yearRange: ClosedRange<Int>?
    var colourwayContains: String?
    var hasPriceOnly: Bool
    var hasNoPriceOnly: Bool

    static let none = RecordsFilter(
        yearRange: nil,
        colourwayContains: nil,
        hasPriceOnly: false,
        hasNoPriceOnly: false
    )

    var isActive: Bool {
        yearRange != nil
            || (colourwayContains?.isEmpty == false)
            || hasPriceOnly
            || hasNoPriceOnly
    }
}

extension Array where Element == VinylRecord {
    func sorted(by sort: RecordsSort) -> [VinylRecord] {
        switch sort {
        case .recentlyUpdated:
            return sorted { $0.updatedAt > $1.updatedAt }
        case .recentlyAdded:
            return sorted { $0.createdAt > $1.createdAt }
        case .artistAZ:
            return sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .titleAZ:
            return sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .yearNewest:
            return sorted { ($0.year ?? Int.min) > ($1.year ?? Int.min) }
        case .yearOldest:
            return sorted { ($0.year ?? Int.max) < ($1.year ?? Int.max) }
        case .priceHighest:
            return sorted { ($0.estimatedPriceCents ?? -1) > ($1.estimatedPriceCents ?? -1) }
        case .priceLowest:
            return sorted { ($0.estimatedPriceCents ?? .max) < ($1.estimatedPriceCents ?? .max) }
        }
    }

    func filtered(by f: RecordsFilter) -> [VinylRecord] {
        guard f.isActive else { return self }
        return filter { record in
            if let range = f.yearRange {
                guard let year = record.year, range.contains(year) else { return false }
            }
            if let needle = f.colourwayContains, !needle.isEmpty {
                guard let cw = record.colourway,
                      cw.localizedCaseInsensitiveContains(needle) else { return false }
            }
            if f.hasPriceOnly && record.estimatedPriceCents == nil { return false }
            if f.hasNoPriceOnly && record.estimatedPriceCents != nil { return false }
            return true
        }
    }
}
