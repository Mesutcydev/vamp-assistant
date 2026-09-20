import AppKit
import SwiftUI

/// Shared sidebar section chrome. The whole header is the expand/collapse hit
/// target, but the header stays a text-first divider instead of another raised
/// card. Project names keep their native casing; only the small eyebrow labels
/// use tracking, so user-created workspaces do not feel like decorative badges.
struct SidebarGroupHeader: View {
    var icon: String
    var appIcon: NSImage? = nil
    var name: String
    var count: Int?
    var expanded: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 9)
            headerGlyph
            Text(name)
                .font(AppFont.navigationGroup)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, SidebarMetrics.rowPadding)
        // Compact project row: a hierarchy line, not a banner.
        .frame(height: SidebarMetrics.commandRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(count.map { "\(name), \($0) chats" } ?? name)
        .accessibilityHint(expanded ? "Collapse" : "Expand")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var headerGlyph: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Instrument.inkSecondary)
            }
        }
        // The mark is an inserted part: a 20 x 18 molded key in the panel,
        // never a floating icon.
        .frame(width: 20, height: 18)
        .accessibilityHidden(true)
    }
}
