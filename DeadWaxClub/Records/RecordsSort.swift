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
        case .yearNewest:      return "Album year (newest first)"
        case .yearOldest:      return "Album year (oldest first)"
        case .priceHighest:    return "Estimated value (high → low)"
        case .priceLowest:     return "Estimated value (low → high)"
        }
    }
}

enum RecordsGrouping: String, CaseIterable, Identifiable {
    case automatic
    case none
    case artist
    case title
    case year
    case recency
    case price

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .none:      return "None"
        case .artist:    return "Artist"
        case .title:     return "Title"
        case .year:      return "Album year"
        case .recency:   return "Recency"
        case .price:     return "Estimated value"
        }
    }

    func resolved(for sort: RecordsSort) -> RecordsGrouping {
        guard self == .automatic else { return self }

        switch sort {
        case .recentlyUpdated, .recentlyAdded:
            return .recency
        case .artistAZ:
            return .artist
        case .titleAZ:
            return .title
        case .yearNewest, .yearOldest:
            return .year
        case .priceHighest, .priceLowest:
            return .price
        }
    }
}

struct RecordsSection: Identifiable {
    let id: String
    let title: String?
    var records: [VinylRecord]
    var subsections: [RecordsSubsection] = []
}

struct RecordsSubsection: Identifiable {
    let id: String
    let title: String?
    var records: [VinylRecord]
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
            return sorted(by: compareRecentlyUpdated)
        case .recentlyAdded:
            return sorted(by: compareRecentlyAdded)
        case .artistAZ:
            return sorted(by: compareArtistAZ)
        case .titleAZ:
            return sorted(by: compareTitleAZ)
        case .yearNewest:
            return sorted(by: compareYearNewest)
        case .yearOldest:
            return sorted(by: compareYearOldest)
        case .priceHighest:
            return sorted(by: comparePriceHighest)
        case .priceLowest:
            return sorted(by: comparePriceLowest)
        }
    }

    private func compareRecentlyUpdated(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareDateDesc(lhs.updatedAt, rhs.updatedAt) { return result }
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        if let result = compareYearDesc(lhs.displayYear, rhs.displayYear) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func compareRecentlyAdded(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareDateDesc(lhs.createdAt, rhs.createdAt) { return result }
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        if let result = compareYearDesc(lhs.displayYear, rhs.displayYear) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func compareArtistAZ(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareYearAsc(lhs.displayYear, rhs.displayYear) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        if let result = compareDateDesc(lhs.createdAt, rhs.createdAt) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func compareTitleAZ(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareYearAsc(lhs.displayYear, rhs.displayYear) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func compareYearNewest(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareYearDesc(lhs.displayYear, rhs.displayYear) { return result }
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        if let result = compareDateDesc(lhs.updatedAt, rhs.updatedAt) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func compareYearOldest(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareYearAsc(lhs.displayYear, rhs.displayYear) { return result }
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        if let result = compareDateDesc(lhs.updatedAt, rhs.updatedAt) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func comparePriceHighest(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = comparePriceDesc(lhs.estimatedPriceCents, rhs.estimatedPriceCents) { return result }
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareYearDesc(lhs.displayYear, rhs.displayYear) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func comparePriceLowest(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = comparePriceAsc(lhs.estimatedPriceCents, rhs.estimatedPriceCents) { return result }
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareYearAsc(lhs.displayYear, rhs.displayYear) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func sortedWithinGroup(grouping: RecordsGrouping, outerSort: RecordsSort) -> [VinylRecord] {
        switch grouping {
        case .artist:
            return sorted(by: compareArtistReleaseYearAsc)
        case .title:
            return sorted(by: compareTitleGroup)
        case .year:
            return sorted(by: compareArtistTitle)
        case .recency, .price, .automatic, .none:
            return sorted(by: outerSort)
        }
    }

    private func compareArtistReleaseYearAsc(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareYearAsc(lhs.displayYear, rhs.displayYear) { return result }
        if let result = compareDateAsc(lhs.createdAt, rhs.createdAt) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func compareReleaseYearAsc(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareYearAsc(lhs.displayYear, rhs.displayYear) { return result }
        if let result = compareDateAsc(lhs.createdAt, rhs.createdAt) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func compareTitleGroup(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareYearAsc(lhs.displayYear, rhs.displayYear) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    private func compareArtistTitle(_ lhs: VinylRecord, _ rhs: VinylRecord) -> Bool {
        if let result = compareArtistNameAsc(lhs.artist, rhs.artist) { return result }
        if let result = compareStringAsc(lhs.title, rhs.title) { return result }
        return compareIDAsc(lhs.id, rhs.id) ?? false
    }

    func grouped(by sort: RecordsSort, grouping: RecordsGrouping) -> [RecordsSection] {
        let resolvedGrouping = grouping.resolved(for: sort)
        guard resolvedGrouping != .none else {
            return [RecordsSection(id: RecordsGrouping.none.rawValue, title: nil, records: self)]
        }

        var sections: [RecordsSection] = []
        var indexesByID: [String: Int] = [:]

        for record in self {
            let group = groupKey(for: record, sort: sort, grouping: resolvedGrouping)
            if let index = indexesByID[group.id] {
                sections[index].records.append(record)
            } else {
                indexesByID[group.id] = sections.count
                sections.append(RecordsSection(id: group.id, title: group.title, records: [record]))
            }
        }

        sections = sections.map { section in
            let records = section.records.sortedWithinGroup(grouping: resolvedGrouping, outerSort: sort)
            return RecordsSection(
                id: section.id,
                title: section.title,
                records: records,
                subsections: resolvedGrouping == .artist
                    ? records.artistSubsections(sectionID: section.id)
                    : []
            )
        }

        if resolvedGrouping == .artist || resolvedGrouping == .title {
            return sections.sorted { lhs, rhs in
                switch (lhs.title, rhs.title) {
                case ("#", "#"):
                    return false
                case ("#", _):
                    return false
                case (_, "#"):
                    return true
                case let (lhsTitle?, rhsTitle?):
                    return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                case (nil, nil):
                    return false
                }
            }
        }

        return sections
    }

    private func groupKey(for record: VinylRecord, sort: RecordsSort, grouping: RecordsGrouping) -> (id: String, title: String) {
        switch grouping {
        case .automatic, .none:
            return (RecordsGrouping.none.rawValue, "")
        case .recency:
            if sort == .recentlyAdded {
                return dateGroup(for: record.createdAt, prefix: "added")
            }
            return dateGroup(for: record.updatedAt, prefix: "updated")
        case .artist:
            return initialGroup(for: artistSortKey(record.artist), prefix: "artist", unknown: "Unknown artist")
        case .title:
            return initialGroup(for: record.title, prefix: "title", unknown: "Untitled")
        case .year:
            guard let year = record.displayYear else { return ("year:unknown", "Unknown year") }
            return ("year:\(year)", String(year))
        case .price:
            return priceGroup(for: record.estimatedPriceCents)
        }
    }

    private func dateGroup(for date: Date, prefix: String) -> (id: String, title: String) {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            return ("\(prefix):today", "Today")
        }
        if calendar.isDateInYesterday(date) {
            return ("\(prefix):yesterday", "Yesterday")
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day {
            if days < 7 { return ("\(prefix):week", "Previous 7 days") }
            if days < 30 { return ("\(prefix):month", "Previous 30 days") }
        }

        let year = calendar.component(.year, from: date)
        return ("\(prefix):\(year)", String(year))
    }

    private func initialGroup(for value: String, prefix: String, unknown: String) -> (id: String, title: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return ("\(prefix):unknown", unknown) }
        let title = String(first).uppercased()
        let isLetterOrNumber = first.isLetter || first.isNumber
        return isLetterOrNumber ? ("\(prefix):\(title)", title) : ("\(prefix):symbols", "#")
    }

    private func priceGroup(for cents: Int?) -> (id: String, title: String) {
        guard let cents else { return ("price:unknown", "No estimate") }
        switch cents {
        case 10_000...:
            return ("price:100-plus", "100+")
        case 5_000..<10_000:
            return ("price:50-99", "50-99")
        case 2_500..<5_000:
            return ("price:25-49", "25-49")
        case 1_000..<2_500:
            return ("price:10-24", "10-24")
        default:
            return ("price:under-10", "Under 10")
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

    private func compareArtistNameAsc(_ lhs: String, _ rhs: String) -> Bool? {
        if let result = compareStringAsc(artistSortKey(lhs), artistSortKey(rhs)) { return result }
        return compareStringAsc(lhs, rhs)
    }

    private func artistSortKey(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixRange = trimmed.startIndex..<trimmed.index(trimmed.startIndex, offsetBy: Swift.min(4, trimmed.count))
        guard trimmed.range(of: "the ", options: [.caseInsensitive], range: prefixRange) != nil else { return trimmed }
        return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compareDateDesc(_ lhs: Date, _ rhs: Date) -> Bool? {
        if lhs == rhs { return nil }
        return lhs > rhs
    }

    private func compareDateAsc(_ lhs: Date, _ rhs: Date) -> Bool? {
        if lhs == rhs { return nil }
        return lhs < rhs
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

    private func compareIDAsc(_ lhs: String, _ rhs: String) -> Bool? {
        if lhs == rhs { return nil }
        return lhs < rhs
    }

    private func artistSubsections(sectionID: String) -> [RecordsSubsection] {
        var subsections: [RecordsSubsection] = []
        var indexesByID: [String: Int] = [:]
        let countsByArtistID = Dictionary(grouping: self) { subsectionIDComponent(for: artistSortKey($0.artist)) }
            .mapValues(\.count)

        for record in self {
            let title = subsectionTitle(for: record.artist, fallback: "Unknown artist")
            let artistID = subsectionIDComponent(for: artistSortKey(record.artist))
            let id = "\(sectionID):artist:\(artistID)"
            let groupTitle = (countsByArtistID[artistID] ?? 0) > 2 ? title : nil
            if let index = indexesByID[id] {
                subsections[index].records.append(record)
            } else {
                indexesByID[id] = subsections.count
                subsections.append(RecordsSubsection(id: id, title: groupTitle, records: [record]))
            }
        }

        return subsections
    }

    private func subsectionTitle(for value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func subsectionIDComponent(for value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "-")
    }

    func filtered(by f: RecordsFilter) -> [VinylRecord] {
        guard f.isActive else { return self }
        return filter { record in
            if !f.statuses.isEmpty && !f.statuses.contains(record.status) { return false }
            if let range = f.yearRange {
                guard let year = record.displayYear, range.contains(year) else { return false }
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
