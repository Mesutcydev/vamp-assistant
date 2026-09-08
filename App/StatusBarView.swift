import SwiftUI

/// Status strip immediately above the composer. Reference export: 30pt high,
/// 22pt side padding, 18pt item gap. Ordering: activity → model/runtime →
/// workspace → changed-file count → trailing context. Every value is real.
struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        ViewThatFits(in: .horizontal) {
            statusRow(includeSecondary: true)
            statusRow(includeSecondary: false)
        }
        .padding(.horizontal, Chrome.statusHPadding)
        .foregroundStyle(Theme.secondaryOnSilver)
        .lineLimit(1)
        .frame(minHeight: 30, maxHeight: 30)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Instrument.silverTop, Instrument.silverMid],
                           startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.structuralDivider.opacity(0.6)).frame(height: 0.75)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.4)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func statusRow(includeSecondary: Bool) -> some View {
        HStack(spacing: 0) {
            activityChip

            chip(icon: "cpu", tint: Theme.textTertiary) {
                Text(modelRuntimeLabel)
                    .lineLimit(1)
            }
            .help(appState.statusModelHelp)
            .layoutPriority(2)

            if let workspace = appState.sessions.workspaceURL {
                chip(icon: "folder", tint: Theme.textTertiary) {
                    Text(workspace.lastPathComponent)
                }
                .help(workspace.path)
            }

            if changedFileCount > 0 {
                chip(icon: "arrow.triangle.branch", tint: Theme.textTertiary) {
                    Text("\(changedFileCount) FILE\(changedFileCount == 1 ? "" : "S") CHANGED")
                }
                .help("Files edited in the current turn")
            }

            Spacer(minLength: 0)

            if includeSecondary, let tps = appState.lastEngineStats.tokensPerSecond, tps > 0 {
                Text(String(format: "%.0f tok/s", tps))
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .help("Tokens per second from the last generation")
            }

            if includeSecondary, appState.sessionUsage.totalTokens > 0 {
                Text(contextLabel)
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
                    .help("This chat: \(appState.sessionUsage.promptTokens) prompt + \(appState.sessionUsage.completionTokens) completion tokens across \(appState.sessionUsage.turns) generation(s).")
            }
        }
    }

    private var activityChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(activityDot)
                .frame(width: 6, height: 6)
            if appState.sessions.isRunning {
                ProgressView().controlSize(.mini)
            }
            Text(activityLabel)
                .font(.appUI(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Instrument.engraved)
        }
        .padding(.trailing, 14)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Instrument.seam.opacity(0.45)).frame(width: 0.75, height: 16)
        }
        .accessibilityLabel("Agent phase: \(activityLabel)")
        .layoutPriority(2)
    }

    private var activityLabel: String {
        let phase = appState.sessions.currentPhase
        if appState.sessions.pendingApproval != nil { return "NEEDS APPROVAL" }
        if appState.sessions.pendingPlan != nil { return "REVIEW PLAN" }
        if appState.sessions.pendingQuestion != nil { return "NEEDS ANSWER" }
        switch phase {
        case .planning: return "PLANNING"
        case .awaitingPlanApproval: return "REVIEW PLAN"
        case .working: return "WORKING"
        case .awaitingApproval: return "NEEDS APPROVAL"
        case .awaitingQuestion: return "NEEDS ANSWER"
        case .verifying: return "VERIFYING"
        case .finished: return "FINISHED"
        case .idle: return appState.sessions.isRunning ? "WORKING" : "READY"
        }
    }

    private var activityDot: Color {
        switch appState.sessions.currentPhase {
        case .awaitingApproval, .awaitingPlanApproval, .awaitingQuestion:
            Theme.warning
        case .working, .planning, .verifying:
            Theme.info
        case .finished:
            Theme.positive
        case .idle:
            Theme.statusNeutral
        }
    }

    private var modelRuntimeLabel: String {
        if let tps = appState.lastEngineStats.tokensPerSecond, tps > 0 {
            // When width is generous the secondary tok/s sits trailing; here
            // it stays beside the model name so ViewThatFits can drop it.
            _ = tps
        }
        return appState.statusModelLabel
    }

    private var changedFileCount: Int {
        CompletionSnapshot.make(transcript: appState.sessions.transcript).changedFileCount
    }

    private var contextLabel: String {
        let total = appState.sessionUsage.totalTokens
        guard total > 0 else { return "" }
        if total >= 10_000 {
            return String(format: "%.1fk context", Double(total) / 1_000)
        }
        return "\(total) context"
    }

    private func chip<Content: View>(
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            content()
        }
        .font(.appUI(size: 10, weight: .medium))
        .tracking(0.45)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 14)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Instrument.seam.opacity(0.45)).frame(width: 0.75, height: 16)
        }
    }
}
