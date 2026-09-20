import SwiftUI

// MARK: - Approval preview

/// Shows what an approval request would actually do: the unified diff for a
/// file edit, or the exact command for a shell run.
///
/// This is the phone's review surface. Approving from a phone is the common
/// case — you are away from the desk when the agent stops and asks — so it is
/// the one screen that most needs to show the change rather than describe it.
struct RemoteApprovalPreviewView: View {
    let preview: RemoteApprovalPreview
    @Environment(\.remoteAppearance) private var appearance
    /// Long diffs start collapsed: an approval card that pushes its own buttons
    /// off screen is worse than one that makes you tap once to see more.
    @ScaledMetric(relativeTo: .footnote) private var codeFontSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var codeLineHeight: CGFloat = 20
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let collapsedLines = 14

    private var parsed: (shown: [String], hidden: Int) { preview.lines() }

    private var visibleLines: [String] {
        expanded ? parsed.shown : Array(parsed.shown.prefix(Self.collapsedLines))
    }

    private var remaining: Int {
        let hiddenByCollapse = expanded ? 0 : max(0, parsed.shown.count - Self.collapsedLines)
        return hiddenByCollapse + parsed.hidden
    }

    var body: some View {
        if preview.hasContent {
            VStack(alignment: .leading, spacing: 8) {
                header
                lineList
                if remaining > 0 || (expanded && parsed.shown.count > Self.collapsedLines) {
                    Button {
                        withAnimation(reduceMotion ? nil : RemoteInstrument.motion) { expanded.toggle() }
                    } label: {
                        Text(expanded ? "Show less" : "Show \(remaining) more line\(remaining == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BeetTheme.accentBright)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RemotePressButtonStyle())
                }
            }
            .padding(11)
            .remoteRecess()
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: preview.isDiff ? "doc.text" : "terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .accessibilityHidden(true)
            Text(preview.isDiff ? (preview.path ?? "Edit") : "Command")
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if preview.isDiff, let added = preview.added, let removed = preview.removed {
                Text("+\(added)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Self.addedText)
                Text("-\(removed)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Self.removedText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(diffAccessibilitySummary)
    }

    private var lineList: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: codeFontSize, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: codeLineHeight)
                        .foregroundStyle(color(for: line))
                        .padding(.horizontal, 6)

                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: line))
                }
            }
            .padding(.vertical, 2)
            .textSelection(.enabled)
        }
        .frame(height: min(CGFloat(visibleLines.count) * codeLineHeight + 4, 240))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preview.isDiff
                            ? "Diff, \(parsed.shown.count) lines"
                            : "Command: \(preview.content ?? "")")
    }

    // Diff colouring. Only applied to real diffs — a shell command is one
    // block of text and must not have its leading dashes read as deletions.
    private static let addedText = RemoteInstrument.green
    private static let removedText = RemoteInstrument.danger

    private func color(for line: String) -> Color {
        guard preview.isDiff else { return RemoteInstrument.ink }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return BeetTheme.secondaryText(appearance)
        }
        if line.hasPrefix("+") { return Self.addedText }
        if line.hasPrefix("-") { return Self.removedText }
        return RemoteInstrument.ink
    }

    private func background(for line: String) -> Color {
        guard preview.isDiff else { return .clear }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Self.addedText.opacity(0.11) }
        if line.hasPrefix("-") { return Self.removedText.opacity(0.11) }
        return .clear
    }

    private var diffAccessibilitySummary: String {
        guard preview.isDiff else { return "Command to run" }
        let path = preview.path ?? "a file"
        let added = preview.added ?? 0
        let removed = preview.removed ?? 0
        return "\(path), \(added) line\(added == 1 ? "" : "s") added, \(removed) removed"
    }
}
