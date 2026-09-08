import SwiftUI

extension View {
    /// Quiet toolbar controls: chrome appears on hover or when the control is
    /// carrying non-default state, keeping the editor visually dominant.
    func lfComposerPill(active: Bool) -> some View {
        modifier(ComposerPillModifier(active: active))
    }
}

private struct ComposerPillModifier: ViewModifier {
    let active: Bool
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .font(.app(size: 11.5, weight: .medium))
            .foregroundStyle(active ? Color.white : Instrument.ink)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Chrome.chipHPadding)
            .frame(minHeight: Chrome.chipHeight)
            .background(
                active
                    ? AnyShapeStyle(Instrument.darkInsert)
                    : AnyShapeStyle(LinearGradient(
                        colors: [Instrument.controlHighlight, Instrument.recessFill],
                        startPoint: .top, endPoint: .bottom)),
                in: chipShape)
            .overlay(chipShape.strokeBorder(
                active ? Color.white.opacity(0.12) : Instrument.seam.opacity(0.7),
                lineWidth: 0.75))
            .contentShape(chipShape)
            .brightness(isHovering ? 0.035 : 0)
            .onHover { hovering in
                if reduceMotion {
                    isHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHovering = hovering
                    }
                }
            }
            .pointerStyle(isHovering ? .link : .default)
    }

    private var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Chrome.chipRadius, style: .continuous)
    }

}
