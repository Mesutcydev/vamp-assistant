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
    @State private var expanded = false

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
                if remaining > 0 {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                    } label: {
                        Text(expanded ? "Show less" : "Show \(remaining) more line\(remaining == 1 ? "" : "s")")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BeetTheme.accentBright)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(11)
            .background(BeetTheme.surfaceStrong(appearance),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(BeetTheme.line(appearance).opacity(0.7), lineWidth: 0.75)
            }
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
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: line))
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: expanded ? 420 : .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preview.isDiff
                            ? "Diff, \(parsed.shown.count) lines"
                            : "Command: \(preview.content ?? "")")
    }

    // Diff colouring. Only applied to real diffs — a shell command is one
    // block of text and must not have its leading dashes read as deletions.
    private static let addedText = Color(red: 0.16, green: 0.55, blue: 0.30)
    private static let removedText = Color(red: 0.70, green: 0.20, blue: 0.22)

    private func color(for line: String) -> Color {
        guard preview.isDiff else { return .primary }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            return BeetTheme.secondaryText(appearance)
        }
        if line.hasPrefix("+") { return Self.addedText }
        if line.hasPrefix("-") { return Self.removedText }
        return .primary
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
