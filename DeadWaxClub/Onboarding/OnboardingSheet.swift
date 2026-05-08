import SwiftUI

/// Single-card onboarding sheet that pages between the steps the user still
/// needs to complete. Replaces the old "one sheet per step" flow which would
/// dismiss + re-present between steps and flash the screen.
///
/// Each step's body lives in its own view (`DiscogsTokenOnboardingView`,
/// `EnableNotificationsView`) — this view just owns the page indicator and
/// the advance-on-completion logic.
struct OnboardingSheet: View {
    /// Steps the parent computed when the sheet first opened. The sheet
    /// captures this snapshot in `@State` and walks it locally so completing
    /// a step (which makes the parent's `pendingSteps` shrink) doesn't pull
    /// the rug out from under us mid-flow.
    let initialSteps: [OnboardingStep]
    let onCompleteDiscogsToken: () -> Void
    let onSkipDiscogsToken: () -> Void
    let onCompleteNotifications: () -> Void

    @State private var steps: [OnboardingStep] = []
    @State private var index: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            if steps.count > 1 {
                pageIndicator
                    .padding(.top, Theme.Spacing.lg)
            }

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // .id forces SwiftUI to treat each step's body as a distinct
                // view, so the transition animates rather than re-using the
                // hierarchy with new bindings.
                .id(currentStep)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                )
        }
        .animation(.easeInOut(duration: 0.25), value: index)
        .onAppear {
            if steps.isEmpty { steps = initialSteps }
        }
    }

    private var currentStep: OnboardingStep? {
        guard index < steps.count else { return nil }
        return steps[index]
    }

    private var pageIndicator: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(0..<steps.count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Theme.Colors.accent : Theme.Colors.surfaceElevated)
                    .frame(width: i == index ? 22 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: index)
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .discogsToken:
            DiscogsTokenOnboardingView(
                onDone: {
                    onCompleteDiscogsToken()
                    advance()
                },
                onSkip: {
                    onSkipDiscogsToken()
                    advance()
                }
            )
        case .enableNotifications:
            EnableNotificationsView(onDone: {
                onCompleteNotifications()
                advance()
            })
        case .none:
            // Out of steps; the parent reconciles and dismisses the sheet.
            Color.clear
        }
    }

    private func advance() {
        if index + 1 < steps.count {
            index += 1
        }
        // When index reaches the end, the parent's reconcile() empties
        // pendingSteps and the sheet dismisses automatically.
    }
}
