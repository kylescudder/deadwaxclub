import Combine
import Foundation

/// A sync problem shown to the user once. This file is identical in every
/// app; app-specific reports live in `SyncIssueStore+App.swift`.
struct SyncIssue: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class SyncIssueStore: ObservableObject {
    @Published var current: SyncIssue?

    func report(_ issue: SyncIssue) {
        current = issue
    }

    func reportLocalClearFailure() {
        report(SyncIssue(
            title: "Offline data not cleared",
            message: SyncAppConfiguration.localClearFailureMessage
        ))
    }
}
