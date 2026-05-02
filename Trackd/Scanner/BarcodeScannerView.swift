import SwiftUI
import VisionKit

/// Wraps VisionKit's DataScannerViewController for barcode scanning.
/// Calls `onScan` exactly once per detection, then pauses until told to resume.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .code39])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var didScan = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didScan else { return }
            for item in added {
                if case let .barcode(barcode) = item, let payload = barcode.payloadStringValue {
                    didScan = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    dataScanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }
    }
}

/// Convenience wrapper that gracefully handles unsupported devices/permissions.
struct BarcodeScannerHost: View {
    let onScan: (String) -> Void

    var body: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            BarcodeScannerView(onScan: onScan)
                .ignoresSafeArea()
        } else {
            ScannerUnavailableView()
        }
    }
}

private struct ScannerUnavailableView: View {
    var body: some View {
        EmptyState(
            systemImage: "exclamationmark.triangle",
            title: "Scanner unavailable",
            message: "This device doesn't support live barcode scanning. You can still add records manually."
        )
    }
}
