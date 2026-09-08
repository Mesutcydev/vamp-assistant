import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RemoteRootView: View {
    let store: RemoteStore
    @ViewBuilder var body: some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["VAMP_REMOTE_TEST_SCREEN"] == "disconnected-control" {
            RemoteControlView(store: store)
        } else if ProcessInfo.processInfo.environment["VAMP_REMOTE_TEST_SCREEN"] == "composer" {
            RemoteComposerFixture()
        } else if ProcessInfo.processInfo.environment["VAMP_REMOTE_TEST_SCREEN"] == "toolbar" {
            RemoteToolbarFixture()
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
            // Keep dismissal in navigation chrome, away from bottom action decks.
            // Keyboard accessory items can float over safe-area insets on iOS.
            ToolbarItem(placement: .topBarTrailing) {
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
                .accessibilityIdentifier("remote.hideKeyboard")
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

    func remoteFaceplate(radius: CGFloat = RemoteInstrument.panelRadius) -> some View {
        background(RemoteInstrument.panel, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(RemoteInstrument.seam.opacity(0.55), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }

    func remoteRecess(focused: Bool = false) -> some View {
        background(RemoteInstrument.recess, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(RemoteInstrument.seam, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(RemoteInstrument.orange)
                    .frame(width: 2, height: 24)
                    .padding(.leading, 1)
                    .opacity(focused ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }

    func remoteNavigationChrome() -> some View {
        foregroundStyle(RemoteInstrument.ink)
            .toolbarBackground(RemoteInstrument.header, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)

    }
}

enum RemoteGlassRole: Equatable {
    case card, panel, control
}

struct RemoteGlassBackdrop: ViewModifier {
    let radius: CGFloat
    var role: RemoteGlassRole = .card

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: min(radius, RemoteInstrument.panelRadius))
                .fill(role == .control
                      ? LinearGradient(colors: [RemoteInstrument.recess, RemoteInstrument.recess], startPoint: .top, endPoint: .bottom)
                      : RemoteInstrument.silver)
        }
    }
}

/// Shared mobile materials. Geometry stays mobile; hues follow the Mac family.
enum RemoteInstrument {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let canvas = adaptive(0xECEBE9, 0x1D1D1D)
    static let reading = adaptive(0xF0EFED, 0x232323)
    static let panel = adaptive(0xDEDDDB, 0x2F2F2F)
    static let header = adaptive(0xE0DFDD, 0x272727)
    static let navigation = adaptive(0xDAD9D7, 0x2A2A2A)
    static let ink = adaptive(0x272727, 0xECECEC)
    static let secondaryInk = adaptive(0x595857, 0xB2B2B2)
    static let silverTop = adaptive(0xDEDDDB, 0x3C3C3C)
    static let silverMid = adaptive(0xD4D3D1, 0x363636)
    static let silverLow = adaptive(0xCCCBC9, 0x323232)
    static let recess = adaptive(0xC8C7C5, 0x252525)
    static let darkInsert = adaptive(0x242424, 0x181818)
    static let seam = adaptive(0xA6A5A3, 0x4C4C4C)
    static let orange = adaptive(0xB65817, 0xE9954B)
    static let green = adaptive(0x287C43, 0x79AF89)
    static let danger = adaptive(0xA73730, 0xE58E87)
    static let silver = LinearGradient(colors: [silverTop, silverLow], startPoint: .top, endPoint: .bottom)
    static let edge = LinearGradient(colors: [adaptive(0xF7F8F2, 0x595959), seam], startPoint: .top, endPoint: .bottom)
    static let panelRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8
    static let hairline: CGFloat = 0.75
    static let controlHeight: CGFloat = 44
    static let contentWidth: CGFloat = 740
    static let composerWidth: CGFloat = 800
    static let motion = Animation.spring(response: 0.28, dampingFraction: 1)
    enum Space {
        static let small: CGFloat = 8
        static let inset: CGFloat = 12
        static let page: CGFloat = 16
        static let section: CGFloat = 20
    }
    enum TypeStyle {
        static let section = Font.caption2.monospaced().weight(.semibold)
        static let title = Font.title2.weight(.semibold)
        static let metadata = Font.caption.monospaced()
        static let utility = Font.subheadline
    }
}

struct RemoteBackdrop: View {
    var body: some View {
        RemoteInstrument.canvas
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Shared warning geometry; action ownership stays with the calling screen.
struct RemoteNoticeLabel: View {
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var symbol = "exclamationmark.circle.fill"
    var isWorking = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: RemoteInstrument.Space.small))
            : AnyLayout(HStackLayout(alignment: .center, spacing: RemoteInstrument.Space.inset))
        layout {
            HStack(alignment: .top, spacing: RemoteInstrument.Space.inset) {
                Group {
                    if isWorking { ProgressView().tint(RemoteInstrument.orange) }
                    else { Image(systemName: symbol).foregroundStyle(RemoteInstrument.orange) }
                }
                .font(.system(size: 18, weight: .medium))
                .frame(width: 22, height: 24)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(RemoteInstrument.ink)
                    Text(detail).font(.caption).foregroundStyle(RemoteInstrument.secondaryInk)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let actionTitle {
                Text(actionTitle).font(.subheadline.weight(.semibold))
                    .foregroundStyle(BeetTheme.accentBright)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
                    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 34 : 0)
            }
        }
        .padding(.horizontal, RemoteInstrument.Space.inset)
        .padding(.vertical, verticalSizeClass == .compact ? 0 : RemoteInstrument.Space.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RemoteInstrument.panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(RemoteInstrument.orange).frame(width: 2)
                .padding(.vertical, RemoteInstrument.Space.inset).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
    }
}

/// Configuration panels share one grid rather than a stack of separate cards.
struct RemoteConsoleSection<Content: View>: View {
    let index: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(index).foregroundStyle(RemoteInstrument.secondaryInk)
                Text("/ " + title.uppercased()).foregroundStyle(RemoteInstrument.secondaryInk)
            }
            .font(.caption2.monospaced().weight(.medium)).tracking(1.5)
            .accessibilityAddTraits(.isHeader)
            VampHairline()
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RemoteConfigurationRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            Text(title.uppercased()).font(.caption.monospaced())
                .foregroundStyle(RemoteInstrument.secondaryInk)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            value.font(.body.weight(.medium)).foregroundStyle(RemoteInstrument.ink)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { VampHairline() }
    }
}

/// Page sections use typography and seams; only working modules get a faceplate.
struct RemoteFormSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VampMicroLabel(title: title)
            VampHairline()
            VStack(alignment: .leading, spacing: RemoteInstrument.Space.inset) { content }
                .font(RemoteInstrument.TypeStyle.utility)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(RemoteInstrument.ink)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("Appearance, \(current.label)")
    }
}

/// Renders sections as a continuous technical page, with no card-per-section. Section
/// and row identities come from SwiftUI, preserving bindings and navigation.
struct RemoteInstrumentForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: RemoteInstrument.Space.section) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if !section.header.isEmpty {
                            ForEach(section.header) { header in
                                header
                                    .font(RemoteInstrument.TypeStyle.section)
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                    .foregroundStyle(RemoteInstrument.secondaryInk)
                                    .textCase(.uppercase)
                                    .tracking(1.2)
                            }
                            VampHairline()
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(section.content) { row in
                                row.frame(maxWidth: .infinity, alignment: .leading)
                                if row.id != section.content.last?.id {
                                    Divider().overlay(RemoteInstrument.seam)
                                }
                            }
                        }
                        .padding(.vertical, section.header.isEmpty ? 0 : 4)
                        if !section.footer.isEmpty {
                            ForEach(section.footer) { footer in
                                footer.font(.footnote)
                                    .foregroundStyle(RemoteInstrument.secondaryInk)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .font(.subheadline)
        .foregroundStyle(RemoteInstrument.ink)
        .pickerStyle(.menu)
        .background(RemoteInstrument.canvas)
    }
}

struct RemoteInstrumentSegments<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(title: String, value: Selection)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(selection == option.value ? .white : RemoteInstrument.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selection == option.value ? RemoteInstrument.darkInsert : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottom) {
                            Capsule().fill(RemoteInstrument.orange)
                                .frame(width: 12, height: 2).padding(.bottom, 4)
                                .opacity(selection == option.value ? 1 : 0)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(RemotePressButtonStyle())
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .animation(reduceMotion ? nil : RemoteInstrument.motion, value: selection)
        .padding(4)
        .background(RemoteInstrument.recess, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(RemoteInstrument.seam, lineWidth: 0.75) }
    }
}

/// Activity stops in the background and respects Reduce Motion.
struct RemoteSignal: View {
    let color: Color
    var isActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating,
                          isActive: isActive && !reduceMotion && scenePhase == .active)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

/// A color signal always accompanied by readable state text.
struct RemoteMobileStatus: View {
    let title: String
    let color: Color
    var isActive = false
    var body: some View {
        HStack(spacing: 6) {
            RemoteSignal(color: color, isActive: isActive)
            Text(title).font(.caption.monospaced())
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shared structural primitives used by production pages and the composer.
struct VampHairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(RemoteInstrument.seam)
            .frame(width: vertical ? RemoteInstrument.hairline : nil,
                   height: vertical ? nil : RemoteInstrument.hairline)
            .accessibilityHidden(true)
    }
}

/// The two edges of a shallow channel separating adjacent hardware bays.
struct VampHardwareSeam: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(RemoteInstrument.seam)
            Rectangle().fill(RemoteInstrument.adaptive(0xF1F0EE, 0x484848))
        }
        .frame(width: 1.5, height: 42)
        .accessibilityHidden(true)
    }
}

struct VampMicroLabel: View {
    let title: String
    var body: some View {
        Text(title).textCase(.uppercase)
            .font(RemoteInstrument.TypeStyle.section).tracking(1.2)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(RemoteInstrument.secondaryInk)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Keep utility actions compact on systems that group toolbar items in glass.
extension ToolbarContent {
    @ToolbarContentBuilder
    func vampUtilityAction() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

#if DEBUG
import SwiftUI

/// Standalone preview of the conversation toolbar's mode toggles, so the
/// active-shade design and alignment can be QA'd without a live Mac session.
struct RemoteToolbarFixture: View {
    @State private var auto = true
    @State private var full = false

    private var preset: String? {
        ProcessInfo.processInfo.environment["VAMP_TOOLBAR_PRESET"]
    }

    var body: some View {
        ZStack {
            RemoteBackdrop()
            VStack(spacing: 20) {
                Spacer()
                VStack(spacing: 8) {
                    Text("CONVERSATION TOOLBAR").font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(RemoteInstrument.secondaryInk).tracking(1.2)
                    VStack(alignment: .trailing, spacing: 10) {
                        VampModeToggle(
                            title: "AUTO",
                            isOn: auto,
                            isDisabled: false) { auto.toggle(); full = false }
                        VampModeToggle(
                            title: "FULL",
                            isOn: full,
                            isDisabled: false) { full.toggle(); auto = false }
                    }
                }
                .padding(20)
                .background(RemoteInstrument.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(RemoteInstrument.seam.opacity(0.5), lineWidth: 0.75) }
                Text("auto:\(String(auto))  full:\(String(full))")
                    .font(.caption2.monospaced()).foregroundStyle(RemoteInstrument.secondaryInk)
                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .environment(\.remoteAppearance, .dark)
        .preferredColorScheme(.dark)
        .onAppear {
            if preset == "full" { auto = false; full = true }
        }
    }
}
#endif
