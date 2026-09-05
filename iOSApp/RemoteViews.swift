import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RemoteRootView: View {
    let store: RemoteStore
    @ViewBuilder var body: some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["VAMP_REMOTE_TEST_SCREEN"] == "disconnected-control" {
            RemoteControlView(store: store)
        } else if store.hasSavedConnection { SessionNavigationView(store: store) }
        else { PairingView(store: store) }
#else
        if store.hasSavedConnection { SessionNavigationView(store: store) }
        else { PairingView(store: store) }
#endif
    }
}

private struct KeyboardDismissToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil)
                } label: {
                    Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Hide keyboard")
            }
        }
    }
}

extension View {
    func keyboardDismissToolbar() -> some View {
        modifier(KeyboardDismissToolbarModifier())
    }

    /// ponytail: grows the hit rect to the 44pt HIG minimum without moving the
    /// visual — the negative padding hands the original size back to the layout,
    /// so the crowded header row does not reflow.
    func hitTarget(_ inset: CGFloat = 5) -> some View {
        padding(inset).contentShape(Rectangle()).padding(-inset)
    }

    /// Shared companion glass. The backdrop follows the ForgeSign/SiteAgent
    /// recipe the Mac client already uses: native Liquid Glass on iOS 26+,
    /// geometry-locked behind a `Color.clear` so the effect never enters layout
    /// measurement, colorless, with the per-role opacity doing the work instead
    /// of an opaque tint. The rim and shadow stay — they are Vamp's silhouette.
    func remoteGlass(
        _ appearance: RemoteAppearance,
        radius: CGFloat,
        strong: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return modifier(RemoteGlassBackdrop(radius: radius, role: strong ? .panel : .card))
            .overlay {
                shape.stroke(
                    LinearGradient(
                        // ponytail: a white highlight is invisible on the light
                        // backdrop, so light mode lost the top-left edge entirely.
                        // Light gets a plain hairline; dark keeps the lit rim.
                        colors: appearance == .light
                            ? [BeetTheme.line(appearance), BeetTheme.line(appearance).opacity(0.45)]
                            : [.white.opacity(0.18), BeetTheme.line(appearance)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(appearance == .light ? 0.10 : 0.28), radius: 22, y: 12)
    }
}

/// Grouped-list rows over the app's backdrop.
///
/// A stock `insetGrouped` list paints opaque cells, which would hide the
/// engraving entirely. Thinning the system cell colour keeps the platform's
/// own row geometry and semantics while letting the backdrop read — and it
/// goes fully opaque for anyone who has asked for less transparency.
struct RemoteListRowBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.listRowBackground(
            Color(uiColor: .secondarySystemGroupedBackground)
                .opacity(reduceTransparency ? 1 : 0.88))
    }
}

extension View {
    func remoteListRow() -> some View { modifier(RemoteListRowBackground()) }
}

/// Surface roles for the companion glass. Each role owns how much of the
/// backdrop it lets through: broad surfaces stay transparent enough for the
/// engraving to read, compact controls keep a visible optical rim.
enum RemoteGlassRole {
    case card, panel, control

    var materialOpacity: Double {
        switch self {
        case .card: 0.30
        case .panel: 0.46
        case .control: 0.52
        }
    }

    var isInteractive: Bool { self == .control }
}

/// Keeps Liquid Glass out of layout measurement: a `Color.clear` sized by the
/// surrounding geometry carries the effect, so the content keeps its natural
/// size. Falls back to a material pre-26 and whenever Reduce Transparency is on.
struct RemoteGlassBackdrop: ViewModifier {
    let radius: CGFloat
    var role: RemoteGlassRole = .card
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.remoteAppearance) private var appearance

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            // Opaque on purpose: the whole point of the setting is no backdrop.
            content.background(BeetTheme.surface(appearance).opacity(1), in: shape)
        } else if #available(iOS 26.0, *) {
            content.background {
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(
                            role.isInteractive ? Glass.clear.interactive() : Glass.clear,
                            in: .rect(cornerRadius: radius))
                        .opacity(role.materialOpacity)
                        .allowsHitTesting(false)
                }
            }
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .background(BeetTheme.surface(appearance).opacity(0.22), in: shape)
        }
    }
}

/// The engraved atmosphere behind every screen.
///
/// It can be turned off in Settings: on a small phone, over dense text, some
/// people just want a flat surface — and a plain background is also the most
/// reliable way to get maximum contrast without leaving the app's palette.
struct RemoteBackdrop: View {
    @AppStorage(RemoteBackdropSetting.key) private var showsAtmosphere = true
    @Environment(\.remoteAppearance) private var appearance
    @ViewBuilder var body: some View {
        if showsAtmosphere { atmosphere } else { BeetTheme.background(appearance).ignoresSafeArea() }
    }

    private var atmosphere: some View {
        GeometryReader { proxy in
            Image("WindowAtmosphere")
                .resizable()
                .scaledToFill()
                .saturation(0)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(appearance == .light
                    ? Color.white.opacity(0.70)
                    : Color.black.opacity(0.64))
                .overlay {
                    LinearGradient(
                        colors: appearance == .light
                            ? [.white.opacity(0.30), .white.opacity(0.68)]
                            : [.black.opacity(0.12), .black.opacity(0.50)],
                        startPoint: .top,
                        endPoint: .bottom)
                }
                .accessibilityHidden(true)
        }
        .background(BeetTheme.background(appearance))
        .ignoresSafeArea()
    }
}

struct AppearanceMenuButton: View {
    @AppStorage("remoteAppearanceSetting") private var setting = RemoteAppearanceSetting.dark
    @Environment(\.remoteAppearance) private var current
    var body: some View {
        Menu {
            Picker("Appearance", selection: $setting) {
                ForEach(RemoteAppearanceSetting.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BeetTheme.secondaryText(current))
                .frame(width: 40, height: 40)
                .hitTarget(2)
                .background(.thinMaterial, in: Circle())
                .background(BeetTheme.surface(current).opacity(0.2), in: Circle())
                .overlay { Circle().stroke(BeetTheme.line(current).opacity(0.7), lineWidth: 0.75) }
                .shadow(color: .black.opacity(current == .light ? 0.08 : 0.18), radius: 9, y: 4)
                .contentShape(Circle())
        }
        .accessibilityLabel("Appearance, \(current.label)")
    }
}

/// Where the backdrop toggle lives, so the view and the settings screen cannot
/// drift apart on the key or the default.
enum RemoteBackdropSetting {
    static let key = "remoteShowsBackdrop"
}
