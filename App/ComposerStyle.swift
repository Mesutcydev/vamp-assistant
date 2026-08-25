import SwiftUI

/// The SwiftUI palette for each composer flow preset. The enum itself lives
/// in Core (ComposerFlow.swift) so SettingsStore and the CLI can see it
/// without importing the UI layer.
/// The state the composer renders for: drives color intensity and the
/// animated border's meaning.
enum ComposerPhase: Equatable {
    case idle
    case focused
    case streaming
    case awaitingApproval

    var borderOpacity: Double {
        switch self {
        case .idle: 0.45
        case .focused: 0.75
        case .streaming: 1.0
        case .awaitingApproval: 1.0
        }
    }
}

/// A restrained native-feeling composer surface. State is communicated by a
/// quiet hairline and a small glow rather than a continuously rotating frame.
struct ComposerBorder: ViewModifier {
    let flow: ComposerFlow
    let phase: ComposerPhase
    var animated: Bool = true

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cornerRadius: CGFloat { Radius.lg }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var stateTint: Color {
        switch phase {
        case .idle: Theme.hairline
        case .focused: Theme.accent
        case .streaming: Theme.info
        case .awaitingApproval: Theme.warning
        }
    }

    func body(content: Content) -> some View {
        content
            .lfGlass(radius: cornerRadius, contentLegibility: true, hovering: isHovering)
            .contentShape(shape)
            .onHover { hovering in
                if reduceMotion {
                    isHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        isHovering = hovering
                    }
                }
            }
            .overlay { interactionBorder.allowsHitTesting(false) }
            .shadow(
                color: phase == .idle ? .clear : stateTint.opacity(animated ? 0.055 : 0.035),
                radius: phase == .idle ? 0 : 5)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: phase)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var interactionBorder: some View {
        if !animated || reduceMotion || flow == .graphite {
            shape.strokeBorder(borderColor, lineWidth: 1)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let progress = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: flow.cycleSeconds) / flow.cycleSeconds
                let angle = Angle.degrees(progress * 360)
                switch flow {
                case .aurora:
                    shape.strokeBorder(
                        AngularGradient(
                            colors: [Theme.hairline, stateTint.opacity(0.28),
                                     Theme.textPrimary.opacity(0.82), stateTint.opacity(0.28),
                                     Theme.hairline],
                            center: .center, angle: angle),
                        lineWidth: 1.35)
                case .ember:
                    shape.strokeBorder(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: Theme.hairline.opacity(0.45), location: 0.00),
                                .init(color: Theme.hairline.opacity(0.45), location: 0.68),
                                .init(color: Theme.textPrimary.opacity(0.95), location: 0.82),
                                .init(color: Theme.hairline.opacity(0.45), location: 0.94),
                                .init(color: Theme.hairline.opacity(0.45), location: 1.00),
                            ]), center: .center, angle: angle),
                        lineWidth: 1.5)
                case .ocean:
                    let pulse = 0.36 + 0.34 * (0.5 + 0.5 * sin(progress * .pi * 2))
                    shape.strokeBorder(stateTint.opacity(pulse), lineWidth: 1.4)
                case .graphite:
                    shape.strokeBorder(borderColor, lineWidth: 1)
                }
            }
        }
    }

    private var borderColor: Color {
        switch phase {
        case .idle:
            return isHovering ? Theme.textTertiary.opacity(0.5) : Theme.hairline
        case .focused:
            return stateTint.opacity(0.34 + (isHovering ? 0.05 : 0))
        case .streaming:
            return stateTint.opacity(0.42 + (isHovering ? 0.05 : 0))
        case .awaitingApproval:
            return stateTint.opacity(0.5 + (isHovering ? 0.05 : 0))
        }
    }
}

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
            .font(.caption.weight(.medium))
            .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Theme.washBorder(Theme.accent) : .clear,
                                            lineWidth: 1))
            .contentShape(Capsule())
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

    private var background: Color {
        if active { return Theme.washStrong(Theme.accent) }
        if isHovering { return Theme.surfaceInset.opacity(0.62) }
        return .clear
    }
}
