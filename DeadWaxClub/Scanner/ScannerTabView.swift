import SwiftUI

struct ScannerTabView: View {
    @EnvironmentObject private var services: AppServices
    @State private var scannedBarcode: String?
    @State private var lookup: DiscogsLookup?
    @State private var existing: VinylRecord?
    @State private var isLooking = false
    @State private var lookupError: String?
    @State private var showResultSheet = false
    @State private var hasToken = false
    @State private var showTokenSheet = false
    // Auto-prompt the token sheet only the first time per app launch so
    // returning to the Scan tab after skipping doesn't re-trap the user.
    @State private var didAutoPromptToken = false

    var body: some View {
        ZStack {
            if hasToken {
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
            } else {
                EmptyState(
                    systemImage: "barcode.viewfinder",
                    title: "Scan needs a Discogs token",
                    message: "Barcode lookup can’t be used without a personal Discogs token. Add one to scan records.",
                    actionTitle: "Add Discogs token"
                ) { showTokenSheet = true }
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
        .sheet(isPresented: $showTokenSheet) {
            NavigationStack {
                DiscogsTokenOnboardingView(
                    onDone: {
                        hasToken = services.discogs.hasToken
                        showTokenSheet = false
                    },
                    onSkip: {
                        showTokenSheet = false
                    }
                )
            }
        }
        .onAppear {
            hasToken = services.discogs.hasToken
            if !hasToken && !didAutoPromptToken {
                didAutoPromptToken = true
                showTokenSheet = true
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
