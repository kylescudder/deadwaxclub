import SwiftUI

struct ScannerTabView: View {
    let defaultStatus: RecordStatus

    @EnvironmentObject private var services: AppServices
    @State private var scannedBarcode: String?
    @State private var lookup: DiscogsLookup?
    @State private var existing: VinylRecord?
    @State private var isLooking = false
    @State private var lookupError: String?
    @State private var showResultSheet = false
    @State private var scannerSessionID = UUID()

    var body: some View {
        ZStack {
            BarcodeScannerHost { barcode in
                Task { await handle(barcode: barcode) }
            }
            .id(scannerSessionID)
            .ignoresSafeArea()

            VStack {
                Spacer()
                if isLooking {
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView().tint(.white)
                        Text("Looking up…").foregroundStyle(.white)
                    }
                    .padding()
                    .background(.black.opacity(0.6))
                    .clipShape(Capsule())
                    .padding(.bottom, Theme.Spacing.xxl)
                }
            }
        }
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Scan failed", isPresented: Binding(
            get: { lookupError != nil },
            set: { if !$0 { reset() } }
        ), presenting: lookupError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
        .sheet(isPresented: $showResultSheet, onDismiss: reset) {
            if let lookup, let barcode = scannedBarcode {
                ScanResultSheet(
                    lookup: lookup,
                    barcode: barcode,
                    existing: existing,
                    initialStatus: defaultStatus
                )
            }
        }
    }

    private func handle(barcode: String) async {
        guard scannedBarcode == nil else {
            Log.breadcrumb("barcode ignored because scan is already in progress", category: "scanner")
            return
        }
        Log.event("barcode scan handling started", category: "scanner", metadata: ["barcodeLength": barcode.count])
        scannedBarcode = barcode
        isLooking = true
        defer { isLooking = false }

        if let userID = services.auth.currentUserID?.lowerUUID,
           let local = await services.records.findByBarcode(barcode, userID: userID) {
            existing = local
            Log.event("barcode matched local record", category: "scanner", metadata: ["recordID": local.id])
        }

        do {
            let result = try await services.discogs.lookup(barcode: barcode)
            lookup = result
            showResultSheet = true
            Log.event("barcode scan lookup succeeded", category: "scanner", metadata: [
                "releaseID": result.releaseID,
                "alreadyInCollection": existing != nil,
            ])
        } catch {
            lookupError = error.localizedDescription
            Log.error(error, category: "scanner.lookup")
        }
    }

    private func reset() {
        Log.breadcrumb("scanner reset", category: "scanner")
        scannedBarcode = nil
        lookup = nil
        existing = nil
        lookupError = nil
        scannerSessionID = UUID()
    }
}
