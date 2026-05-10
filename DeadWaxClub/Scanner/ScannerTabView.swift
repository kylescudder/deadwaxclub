import SwiftUI

struct ScannerTabView: View {
    @EnvironmentObject private var services: AppServices
    @State private var scannedBarcode: String?
    @State private var lookup: DiscogsLookup?
    @State private var existing: VinylRecord?
    @State private var isLooking = false
    @State private var lookupError: String?
    @State private var showResultSheet = false

    var body: some View {
        ZStack {
            BarcodeScannerHost { barcode in
                Task { await handle(barcode: barcode) }
            }
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
            set: { if !$0 { lookupError = nil; scannedBarcode = nil } }
        ), presenting: lookupError) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
        .sheet(isPresented: $showResultSheet, onDismiss: reset) {
            if let lookup, let barcode = scannedBarcode {
                ScanResultSheet(lookup: lookup, barcode: barcode, existing: existing)
            }
        }
    }

    private func handle(barcode: String) async {
        guard scannedBarcode == nil else { return }
        scannedBarcode = barcode
        isLooking = true
        defer { isLooking = false }

        if let userID = services.auth.currentUserID?.lowerUUID,
           let local = await services.records.findByBarcode(barcode, userID: userID) {
            existing = local
        }

        do {
            let result = try await services.discogs.lookup(barcode: barcode)
            lookup = result
            showResultSheet = true
        } catch {
            lookupError = error.localizedDescription
        }
    }

    private func reset() {
        scannedBarcode = nil
        lookup = nil
        existing = nil
    }
}
