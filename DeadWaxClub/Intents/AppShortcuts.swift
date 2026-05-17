import AppIntents

struct DeadWaxClubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogPriceIntent(),
            phrases: [
                "Log a price in \(.applicationName)",
                "Track a vinyl price with \(.applicationName)",
            ],
            shortTitle: "Log price",
            systemImageName: "tag"
        )
        AppShortcut(
            intent: ScanBarcodeIntent(),
            phrases: [
                "Scan a barcode in \(.applicationName)",
                "Scan vinyl with \(.applicationName)",
            ],
            shortTitle: "Scan barcode",
            systemImageName: "barcode.viewfinder"
        )
        AppShortcut(
            intent: AddRecordIntent(),
            phrases: [
                "Add a record in \(.applicationName)",
                "Search for a record in \(.applicationName)",
            ],
            shortTitle: "Add record",
            systemImageName: "plus"
        )
    }
}
