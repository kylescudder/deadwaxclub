import SwiftUI

struct SyncStatusView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sync \(label)")
    }

    private var color: Color {
        switch services.sync.status {
        case .connected:  return .green
        case .connecting: return .orange
        case .offline:    return .gray
        case .error:      return .red
        case .idle:       return .gray
        }
    }

    private var label: String {
        switch services.sync.status {
        case .connected:  return "Synced"
        case .connecting: return "Syncing"
        case .offline:    return "Offline"
        case .error:      return "Sync error"
        case .idle:       return "Idle"
        }
    }
}
