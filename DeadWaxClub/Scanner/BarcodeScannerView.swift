import SwiftUI
import VisionKit
import AVFoundation
import UIKit

/// Wraps VisionKit's DataScannerViewController for barcode scanning.
/// Calls `onScan` exactly once per detection, then pauses until told to resume.
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        Log.breadcrumb("barcode scanner controller created", category: "scanner.camera")
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
            do {
                try controller.startScanning()
                Log.breadcrumb("barcode scanner started", category: "scanner.camera")
            } catch {
                Log.error(error, category: "scanner.camera")
            }
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
        Log.breadcrumb("barcode scanner stopped", category: "scanner.camera")
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
                    Log.event("barcode payload detected", category: "scanner.camera", metadata: ["payloadLength": payload.count])
                    dataScanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }
    }
}

/// Convenience wrapper that gracefully handles unsupported devices,
/// missing capabilities, and a camera-permission denied state.
struct BarcodeScannerHost: View {
    let onScan: (String) -> Void

    @State private var cameraStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var scanCount = 0

    var body: some View {
        Group {
            if !DataScannerViewController.isSupported {
                ScannerUnavailableView(
                    title: "Scanner unavailable",
                    message: "This device doesn't support live barcode scanning. You can still add records manually."
                )
            } else if !DataScannerViewController.isAvailable {
                ScannerUnavailableView(
                    title: "Scanner unavailable right now",
                    message: "Live text/barcode capture is currently disabled by the system."
                )
            } else {
                switch cameraStatus {
                case .authorized:
                    BarcodeScannerView { payload in
                        scanCount += 1
                        onScan(payload)
                    }
                        .ignoresSafeArea()
                case .notDetermined:
                    PermissionPromptView {
                        Task {
                            let granted = await AVCaptureDevice.requestAccess(for: .video)
                            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                            Log.event("camera permission resolved", category: "scanner.camera", metadata: [
                                "granted": granted,
                                "cameraStatus": String(describing: cameraStatus),
                            ])
                        }
                    }
                case .denied, .restricted:
                    CameraDeniedView()
                @unknown default:
                    CameraDeniedView()
                }
            }
        }
        .onAppear {
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            Log.event("scanner host appeared", category: "scanner.camera", metadata: [
                "cameraStatus": String(describing: cameraStatus),
                "isSupported": DataScannerViewController.isSupported,
                "isAvailable": DataScannerViewController.isAvailable,
            ])
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: scanCount)
    }
}

private struct ScannerUnavailableView: View {
    let title: String
    let message: String
    var body: some View {
        EmptyState(systemImage: "exclamationmark.triangle", title: title, message: message)
    }
}

private struct PermissionPromptView: View {
    let onTap: () -> Void
    var body: some View {
        EmptyState(
            systemImage: "camera.viewfinder",
            title: "Allow camera access",
            message: "Deadwax Club uses the camera to scan vinyl barcodes when you're shopping.",
            actionTitle: "Continue",
            action: onTap
        )
    }
}

private struct CameraDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "camera.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.Colors.textTertiary)
            VStack(spacing: Theme.Spacing.sm) {
                Text("Camera access is off")
                    .font(.title3.weight(.semibold))
                Text("Deadwax Club needs camera access to scan vinyl barcodes. Enable it in iOS Settings.")
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            PrimaryButton(title: "Open Settings", systemImage: "gear", fullWidth: false) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
