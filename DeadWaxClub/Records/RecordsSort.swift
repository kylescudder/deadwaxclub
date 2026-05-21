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
    /// Empty set means "any status". Populated set narrows to those statuses.
    /// Only surfaces in the UI on filter sheets that opt-in (currently the
    /// add-to-list picker); the Records tab already filters by status via
    /// its segmented control at the watcher level.
    var statuses: Set<RecordStatus>

    static let none = RecordsFilter(
        yearRange: nil,
        colourwayContains: nil,
        hasPriceOnly: false,
        hasNoPriceOnly: false,
        statuses: []
    )

    var isActive: Bool {
        yearRange != nil
            || (colourwayContains?.isEmpty == false)
            || hasPriceOnly
            || hasNoPriceOnly
            || !statuses.isEmpty
    }
}

extension Array where Element == VinylRecord {
    func sorted(by sort: RecordsSort) -> [VinylRecord] {
        switch sort {
        case .recentlyUpdated:
            return sorted { lhs, rhs in
                compareDateDesc(lhs.updatedAt, rhs.updatedAt)
                    ?? compareStringAsc(lhs.artist, rhs.artist)
                    ?? compareStringAsc(lhs.title, rhs.title)
                    ?? compareYearDesc(lhs.year, rhs.year)
                    ?? compareIDAsc(lhs.id, rhs.id)
                    ?? false
            }
        case .recentlyAdded:
            return sorted { lhs, rhs in
                compareDateDesc(lhs.createdAt, rhs.createdAt)
                    ?? compareStringAsc(lhs.artist, rhs.artist)
                    ?? compareStringAsc(lhs.title, rhs.title)
                    ?? compareYearDesc(lhs.year, rhs.year)
                    ?? compareIDAsc(lhs.id, rhs.id)
                    ?? false
            }
        case .artistAZ:
            return sorted { lhs, rhs in
                compareStringAsc(lhs.artist, rhs.artist)
                    ?? compareYearAsc(lhs.year, rhs.year)
                    ?? compareStringAsc(lhs.title, rhs.title)
                    ?? compareDateDesc(lhs.createdAt, rhs.createdAt)
                    ?? compareIDAsc(lhs.id, rhs.id)
                    ?? false
            }
        case .titleAZ:
            return sorted { lhs, rhs in
                compareStringAsc(lhs.title, rhs.title)
                    ?? compareStringAsc(lhs.artist, rhs.artist)
                    ?? compareYearAsc(lhs.year, rhs.year)
                    ?? compareIDAsc(lhs.id, rhs.id)
                    ?? false
            }
        case .yearNewest:
            return sorted { lhs, rhs in
                compareYearDesc(lhs.year, rhs.year)
                    ?? compareStringAsc(lhs.artist, rhs.artist)
                    ?? compareStringAsc(lhs.title, rhs.title)
                    ?? compareDateDesc(lhs.updatedAt, rhs.updatedAt)
                    ?? compareIDAsc(lhs.id, rhs.id)
                    ?? false
            }
        case .yearOldest:
            return sorted { lhs, rhs in
                compareYearAsc(lhs.year, rhs.year)
                    ?? compareStringAsc(lhs.artist, rhs.artist)
                    ?? compareStringAsc(lhs.title, rhs.title)
                    ?? compareDateDesc(lhs.updatedAt, rhs.updatedAt)
                    ?? compareIDAsc(lhs.id, rhs.id)
                    ?? false
            }
        case .priceHighest:
            return sorted { lhs, rhs in
                comparePriceDesc(lhs.estimatedPriceCents, rhs.estimatedPriceCents)
                    ?? compareStringAsc(lhs.artist, rhs.artist)
                    ?? compareYearDesc(lhs.year, rhs.year)
                    ?? compareStringAsc(lhs.title, rhs.title)
                    ?? compareIDAsc(lhs.id, rhs.id)
                    ?? false
            }
        case .priceLowest:
            return sorted { lhs, rhs in
                comparePriceAsc(lhs.estimatedPriceCents, rhs.estimatedPriceCents)
                    ?? compareStringAsc(lhs.artist, rhs.artist)
                    ?? compareYearAsc(lhs.year, rhs.year)
                    ?? compareStringAsc(lhs.title, rhs.title)
                    ?? compareIDAsc(lhs.id, rhs.id)
                    ?? false
            }
        }
    }

    private func compareStringAsc(_ lhs: String, _ rhs: String) -> Bool? {
        let result = lhs.localizedCaseInsensitiveCompare(rhs)
        switch result {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return nil
        }
    }

    private func compareDateDesc(_ lhs: Date, _ rhs: Date) -> Bool? {
        if lhs == rhs { return nil }
        return lhs > rhs
    }

    /// Unknown years sort last in both directions.
    private func compareYearAsc(_ lhs: Int?, _ rhs: Int?) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?):
            if l == r { return nil }
            return l < r
        case (nil, nil):
            return nil
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        }
    }

    /// Unknown years sort last in both directions.
    private func compareYearDesc(_ lhs: Int?, _ rhs: Int?) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?):
            if l == r { return nil }
            return l > r
        case (nil, nil):
            return nil
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        }
    }

    /// Unknown prices sort last in both directions.
    private func comparePriceAsc(_ lhs: Int?, _ rhs: Int?) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?):
            if l == r { return nil }
            return l < r
        case (nil, nil):
            return nil
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        }
    }

    /// Unknown prices sort last in both directions.
    private func comparePriceDesc(_ lhs: Int?, _ rhs: Int?) -> Bool? {
        switch (lhs, rhs) {
        case let (l?, r?):
            if l == r { return nil }
            return l > r
        case (nil, nil):
            return nil
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        }
    }

    private func compareIDAsc(_ lhs: UUID, _ rhs: UUID) -> Bool? {
        let ls = lhs.uuidString
        let rs = rhs.uuidString
        if ls == rs { return nil }
        return ls < rs
    }

    func filtered(by f: RecordsFilter) -> [VinylRecord] {
        guard f.isActive else { return self }
        return filter { record in
            if !f.statuses.isEmpty && !f.statuses.contains(record.status) { return false }
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
