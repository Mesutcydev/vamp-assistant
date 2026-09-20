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
        } else if ProcessInfo.processInfo.environment["VAMP_REMOTE_TEST_SCREEN"] == "instrument" {
            RemoteInstrumentFixture()
        } else if ProcessInfo.processInfo.environment["VAMP_REMOTE_TEST_SCREEN"] == "new-session" {
            StartSessionSheet(store: store, initialBotID: "", showAdvanced: true) { _ in }
        } else if ProcessInfo.processInfo.environment["VAMP_REMOTE_TEST_SCREEN"] == "bots" {
            RemoteBotsView(store: store) { _ in }
        } else if store.hasSavedConnection { SessionNavigationView(store: store) }
        else { PairingView(store: store) }
#else
        if store.hasSavedConnection { SessionNavigationView(store: store) }
        else { PairingView(store: store) }
#endif
    }
}

private struct KeyboardDismissToolbarModifier: ViewModifier {
    @State private var keyboardVisible = false
    func body(content: Content) -> some View {
        content.toolbar {
            if keyboardVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                        to: nil, from: nil, for: nil)
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.subheadline.weight(.semibold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(RemoteKeyButtonStyle())
                    .accessibilityLabel("Hide keyboard")
                    .accessibilityIdentifier("remote.hideKeyboard")
                }.vampUtilityAction()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
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
            let shape = RoundedRectangle(cornerRadius: min(radius, RemoteInstrument.panelRadius), style: .continuous)
            shape
                .fill(role == .control
                      ? LinearGradient(colors: [RemoteInstrument.recess, RemoteInstrument.recess], startPoint: .top, endPoint: .bottom)
                      : RemoteInstrument.pearl)
                .overlay {
                    shape.strokeBorder(RemoteInstrument.chassisEdge.opacity(0.62), lineWidth: 0.75)
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(RemoteInstrument.housingRim.opacity(role == .control ? 0.18 : 0.46))
                        .frame(height: 0.5)
                        .padding(.horizontal, min(radius, RemoteInstrument.panelRadius))
                }
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
    // Light mode uses a neutral pearl family: a white reading plane with a
    // restrained cool-rose shift through the chassis. It stays luminous
    // without reading as beige metal or flat office gray.
    static let canvas = adaptive(0xF9F8F7, 0x0E0E0E)
    static let reading = adaptive(0xFFFFFF, 0x141414)
    static let panel = adaptive(0xF3F1F2, 0x292929)
    static let header = adaptive(0xF8F7F8, 0x1B1B1B)
    static let navigation = adaptive(0xEEECEF, 0x232323)
    static let ink = adaptive(0x202022, 0xF0EFEC)
    static let secondaryInk = adaptive(0x5F5D61, 0xB7B5B1)
    static let pearlTop = adaptive(0xFFFDFE, 0x383838)
    static let pearlMid = adaptive(0xF5F1F4, 0x323232)
    static let pearlLow = adaptive(0xE7E6EA, 0x292929)
    static let recess = adaptive(0xECE9ED, 0x202020)
    static let darkInsert = adaptive(0x232226, 0x090909)
    static let seam = adaptive(0xB2ADB5, 0x444444)
    static let orange = adaptive(0xC6530A, 0xE9954B)
    static let green = adaptive(0x287C43, 0x79AF89)
    static let danger = adaptive(0xA73730, 0xE58E87)
    // Physical instrument control surfaces. The housing is one machined
    // enclosure; the keys sit inside it, one tonal step brighter so the
    // enclosure edge reads. All three stay legible in both appearances.
    static let housing = adaptive(0xE2DEE4, 0x292929)
    static let housingRim = adaptive(0xFFFFFF, 0x4A4A4A)
    static let housingFoot = adaptive(0xA7A1AA, 0x1A1A1A)
    static let keyFace = adaptive(0xFFFDFE, 0x393939)
    static let keyFacePressed = adaptive(0xE8E4EA, 0x222222)
    static let keyTopHighlight = adaptive(0xFFFFFF, 0x515151)
    static let keyBottomShadow = adaptive(0xAAA4AC, 0x0C0C0C)
    static let keySeam = adaptive(0x7D7880, 0x0E0E0E)
    static let keyInsetShadow = adaptive(0x938D96, 0x000000)
    /// The single hairline that defines a chassis perimeter. One edge, no rails.
    static let chassisEdge = adaptive(0xB7B1BA, 0x393939)
    static let pearl = LinearGradient(colors: [pearlTop, pearlMid, pearlLow], startPoint: .top, endPoint: .bottom)
    static let edge = LinearGradient(colors: [adaptive(0xFFFFFF, 0x595959), seam], startPoint: .top, endPoint: .bottom)
    static let panelRadius: CGFloat = 9
    static let controlRadius: CGFloat = 7
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
            VStack(spacing: 24) {
                ForEach(sections: content) { section in
                    VStack(alignment: .leading, spacing: 10) {
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
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(section.content) { row in
                                row.frame(maxWidth: .infinity, alignment: .leading)
                                if row.id != section.content.last?.id {
                                    Divider().overlay(RemoteInstrument.seam)
                                }
                            }
                        }
                        .padding(.vertical, section.header.isEmpty ? 0 : 2)
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

/// Legacy call sites (theme, tabs, mode and source pickers) all render through
/// the shared instrument key bank now, so every segmented control in the app
/// speaks the same physical language from one source of styling.
struct RemoteInstrumentSegments<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(title: String, value: Selection)]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        InstrumentKeyBank(
            selection: $selection,
            titles: options.map { $0.title.uppercased() },
            values: options.map(\.value),
            isMono: true,
            vertical: dynamicTypeSize.isAccessibilitySize)
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
            Text(title).font(.caption.monospaced()).lineLimit(1)
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

// MARK: - Instrument control system

/// Shared control geometry for the physical instrument language. One machined
/// enclosure, hairline seams, individual keycaps, tiny status indicators.
enum InstrumentGeometry {
    static let separator: CGFloat = 1
    static let border: CGFloat = 1
    static let pressedOffset: CGFloat = 1
    static let insetShadowHeight: CGFloat = 7
}

/// Explicit size variants for the instrument key banks. Each size carries its
/// own metrics so a two-key header switch and a full-width settings bank never
/// share dimensions and never collapse or truncate.
enum InstrumentSize {
    case compact, regular, large

    var height: CGFloat {
        switch self {
        case .compact: return 44
        case .regular: return 50
        case .large: return 78
        }
    }
    var housingRadius: CGFloat {
        switch self {
        case .compact, .regular: return 5
        case .large: return 6
        }
    }
    var keyRadius: CGFloat {
        switch self {
        // Adjacent key edges stay square; only the ends of the bank can be
        // softened after the chassis clips the assembly.
        case .compact, .regular: return 2
        case .large: return 4
        }
    }
    var chamberInset: CGFloat {
        switch self {
        case .compact: return 0
        case .regular, .large: return 3
        }
    }
    var fontSize: CGFloat {
        switch self {
        case .compact: return 14
        case .regular: return 13
        case .large: return 16
        }
    }
    var tracking: CGFloat {
        switch self {
        case .compact: return 0.8
        case .regular: return 1.2
        case .large: return 1.0
        }
    }
    var indicatorWidth: CGFloat {
        switch self {
        case .compact: return 13
        case .regular: return 16
        case .large: return 18
        }
    }
    var indicatorInset: CGFloat {
        switch self {
        case .compact: return 4
        case .regular: return 5
        case .large: return 6
        }
    }
    /// Compact gets a fixed, generous segment width so AUTO/FULL can never
    /// shrink or ellipsize. Regular/large fill the available width.
    var fixedSegmentWidth: CGFloat? {
        switch self {
        case .compact: return 74
        case .regular, .large: return nil
        }
    }
    var minTotalWidth: CGFloat? {
        switch self {
        case .compact: return 152
        case .regular, .large: return nil
        }
    }
}

private struct InstrumentPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var instrumentPressed: Bool {
        get { self[InstrumentPressedKey.self] }
        set { self[InstrumentPressedKey.self] = newValue }
    }
}

/// A stationary housing underneath a moving face. All mobile hardware keys
/// share this rendering, including the existing selection and action banks.
struct RemoteKeySurface: ViewModifier {
    var isPressed = false
    var isSelected = false
    var prominent = false
    var radius: CGFloat = 6
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var engaged: Bool { isSelected || (isPressed && isEnabled) }
    private var face: Color {
        if prominent || isSelected { return RemoteInstrument.darkInsert }
        return engaged ? RemoteInstrument.keyFacePressed : RemoteInstrument.keyFace
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(face)
                    .overlay {
                        shape.strokeBorder(RemoteInstrument.keySeam.opacity(contrast == .increased ? 0.85 : 0.28),
                                           lineWidth: contrast == .increased ? 1.5 : 0.5)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(RemoteInstrument.keyTopHighlight.opacity(engaged ? 0.12 : 0.65))
                            .frame(height: 0.5)
                            .padding(.horizontal, radius)
                            .padding(.top, 0.5)
                    }
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [RemoteInstrument.keyInsetShadow.opacity(engaged ? 0.20 : 0), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 3).clipShape(shape)
                    }
                    .shadow(color: RemoteInstrument.keyBottomShadow.opacity(engaged ? 0 : 0.28),
                            radius: 0, x: 0, y: engaged ? 0 : 1)
            }
            .offset(y: engaged && !reduceMotion ? 1 : 0)
            .padding(.bottom, 1)
            .background(RemoteInstrument.housingFoot.opacity(0.55), in: shape)
            .opacity(isEnabled ? 1 : 0.48)
            .animation(reduceMotion ? nil : .easeOut(duration: isPressed ? 0.08 : 0.14), value: isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isSelected)
    }
}

struct RemoteKeyButtonStyle: ButtonStyle {
    var prominent = false
    var isSelected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? RemoteInstrument.danger :
                                ((prominent || isSelected) ? Color.white : RemoteInstrument.ink))
            .modifier(RemoteKeySurface(isPressed: configuration.isPressed, isSelected: isSelected, prominent: prominent))
    }
}

private struct InstrumentKeyShell<Content: View>: View {
    let isOn: Bool
    let size: InstrumentSize
    let reduceMotion: Bool
    @Environment(\.instrumentPressed) private var pressed
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(RemoteKeySurface(isPressed: pressed, isSelected: isOn, radius: size.keyRadius))
    }
}

/// A tiny rounded status bar: the signature "instrumentation" mark under a
/// selected key. Fully rounded, no glow.
struct InstrumentIndicator: View {
    var color: Color
    var visible: Bool = true
    var width: CGFloat = 14
    var height: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width, height: height)
            .opacity(visible && shown ? 1 : 0)
            .onAppear { shown = visible }
            .onChange(of: visible) { _, v in shown = v }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: shown)
            .accessibilityHidden(true)
    }
}

/// Press behaviour for a physical keycap: a 1pt optical settle and a small
/// surface darken, returning with a subtle spring. No bouncy scale.
struct InstrumentKeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.instrumentPressed, configuration.isPressed)
    }
}

/// One selection option rendered as a physical keycap inside an instrument
/// housing. The active key reads as pressed: darker face, 1pt settle, reduced
/// top highlight, stronger label, and a tiny accent indicator beneath.
struct InstrumentKey: View {
    let isOn: Bool
    let title: String
    var labelColor: Color = RemoteInstrument.ink
    var indicatorColor: Color
    var showsIndicator: Bool = true
    var isMono: Bool = false
    var size: InstrumentSize = .regular
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let font: Font = isMono
            ? .system(size: size.fontSize, weight: .semibold, design: .monospaced)
            : .system(size: size.fontSize, weight: .semibold)
        return InstrumentKeyShell(isOn: isOn, size: size, reduceMotion: reduceMotion) {
            VStack(spacing: 0) {
                Text(title)
                    .font(font)
                    .tracking(isMono ? size.tracking : 0.2)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .foregroundStyle(isOn ? Color.white : labelColor.opacity(0.78))
                InstrumentIndicator(color: indicatorColor, visible: isOn && showsIndicator,
                                    width: size.indicatorWidth, height: 2)
                    .padding(.bottom, size.indicatorInset)
            }
        }
    }
}

/// A unified instrument housing containing equal-width keys separated by
/// hairline seams. One enclosure, N keycaps — the AUTO/FULL switch, the
/// THEME bank, and the large action keys all derive from this so they read
/// as one physical object.
struct InstrumentKeyBank<Selection: Hashable>: View {
    typealias Size = InstrumentSize

    @Binding var selection: Selection
    let titles: [String]
    let values: [Selection]
    var accent: Color = RemoteInstrument.orange
    var showsIndicator = true
    var isMono = false
    var size: InstrumentSize = .regular
    var vertical = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(Array(values.enumerated()), id: \.element) { index, value in
                let isOn = value == selection
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    selection = value
                } label: {
                    InstrumentKey(
                        isOn: isOn,
                        title: titles[index],
                        indicatorColor: accent,
                        showsIndicator: showsIndicator,
                        isMono: isMono,
                        size: size)
                        .frame(width: size.fixedSegmentWidth, height: vertical ? 44 : nil)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InstrumentKeyPressStyle())
                .accessibilityLabel(titles[index])
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .layoutPriority(1)
                if index < values.count - 1 {
                    Rectangle()
                        .fill(RemoteInstrument.keySeam)
                        .frame(width: vertical ? nil : InstrumentGeometry.separator,
                               height: vertical ? InstrumentGeometry.separator : nil)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: size.fixedSegmentWidth == nil ? .infinity : nil)
        .frame(minWidth: size.minTotalWidth)
        .frame(height: vertical ? nil : size.height)
        .padding(size.chamberInset)
        .background(
            RemoteInstrument.housing,
            in: RoundedRectangle(cornerRadius: size.housingRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size.housingRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size.housingRadius, style: .continuous)
                .strokeBorder(RemoteInstrument.chassisEdge, lineWidth: InstrumentGeometry.border)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : RemoteInstrument.motion, value: selection)
    }
}

/// A unified instrument housing for a bank of accent swatches. Each cell is a
/// physical key with a centered circular specimen; selection shows as pressed
/// key + ring + tiny accent line (never a giant checkmark badge).
struct InstrumentAccentBank<Selection: Hashable>: View {
    @Binding var selection: Selection
    let palettes: [Selection]
    let labels: [String]
    let colors: [Color]
    var size: InstrumentSize = .regular
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
            ForEach(Array(palettes.enumerated()), id: \.element) { index, palette in
                let isOn = palette == selection
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    selection = palette
                } label: {
                    InstrumentKeyShell(isOn: isOn, size: size, reduceMotion: reduceMotion) {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                            Text(String(format: "%02d", index + 1))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(RemoteInstrument.secondaryInk)
                                .padding(.top, 5)
                                .padding(.leading, 6)
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(colors[index])
                                    .frame(width: 21, height: 21)
                                InstrumentIndicator(color: RemoteInstrument.orange,
                                                    visible: isOn,
                                                    width: 13, height: 2)
                                    .padding(.top, 5)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .frame(height: max(size.height, 54))
                .buttonStyle(InstrumentKeyPressStyle())
                .accessibilityLabel(labels[index])
                .accessibilityAddTraits(isOn ? .isSelected : [])

            }
        }
        .padding(size.chamberInset)
        .background(
            RemoteInstrument.housing,
            in: RoundedRectangle(cornerRadius: size.housingRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size.housingRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size.housingRadius, style: .continuous)
                .strokeBorder(RemoteInstrument.chassisEdge, lineWidth: InstrumentGeometry.border)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : RemoteInstrument.motion, value: selection)
    }
}

/// One momentary action rendered as a physical keycap with an icon above its
/// label. Three of these in one housing read as a synth key bank, not three
/// unrelated bordered cards.
struct InstrumentAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var index: String? = nil
    var secondary: String? = nil
    var ledColor: Color? = nil
    var ledActive = false
    let action: () -> Void
}

struct InstrumentActionBank: View {
    let actions: [InstrumentAction]
    var size: InstrumentSize = .large
    var vertical = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 0))
        let keyShape = RoundedRectangle(cornerRadius: size.keyRadius, style: .continuous)
        layout {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    action.action()
                } label: {
                    InstrumentKeyShell(isOn: false, size: size, reduceMotion: reduceMotion) {
                        ZStack(alignment: .topLeading) {
                            Color.clear
                            HStack(alignment: .top) {
                                Text(action.index ?? String(format: "%02d", index + 1))
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(RemoteInstrument.secondaryInk)
                                    .padding(.top, 6)
                                    .padding(.leading, 9)
                                Spacer(minLength: 0)
                                Image(systemName: action.symbol)
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(RemoteInstrument.ink.opacity(0.88))
                                    .padding(.top, 5)
                                    .padding(.trailing, 9)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Spacer(minLength: 0)
                                Text(action.title.uppercased())
                                    .font(.system(size: 13, weight: .semibold))
                                    .tracking(0.5)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)
                                    .foregroundStyle(RemoteInstrument.ink)
                                if let secondary = action.secondary {
                                    HStack(spacing: 5) {
                                        if let ledColor = action.ledColor {
                                            RemoteSignal(color: ledColor, isActive: action.ledActive)
                                                .scaleEffect(0.72, anchor: .leading)
                                        }
                                        Text(secondary.uppercased())
                                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                                            .tracking(0.6)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                    }
                                    .foregroundStyle(RemoteInstrument.secondaryInk)
                                }
                            }
                            .padding(.leading, 9)
                            .padding(.trailing, 9)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                    }
                    .contentShape(keyShape)
                }
                .buttonStyle(InstrumentKeyPressStyle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel([action.title, action.secondary].compactMap(\.self).joined(separator: ", "))
                .layoutPriority(1)
                if index < actions.count - 1 {
                    Rectangle()
                        .fill(RemoteInstrument.keySeam)
                        .frame(width: vertical ? nil : InstrumentGeometry.separator,
                               height: vertical ? InstrumentGeometry.separator : nil)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: vertical ? nil : size.height)
        .padding(size.chamberInset)
        .background(
            RemoteInstrument.housing,
            in: RoundedRectangle(cornerRadius: size.housingRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: size.housingRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size.housingRadius, style: .continuous)
                .strokeBorder(RemoteInstrument.chassisEdge, lineWidth: InstrumentGeometry.border)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : RemoteInstrument.motion, value: actions.count)
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

/// Deterministic state plate, sharing the production material modifier.
struct RemoteKeyStatePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Physical controls").font(.title2.weight(.semibold))
            Text("Silver / graphite · 1pt travel").font(.subheadline).foregroundStyle(RemoteInstrument.secondaryInk)
            Text("Resting").frame(maxWidth: .infinity, minHeight: 44)
                .modifier(RemoteKeySurface())
            Text("Pressed").frame(maxWidth: .infinity, minHeight: 44)
                .modifier(RemoteKeySurface(isPressed: true))
            Text("Selected  •").foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44)
                .modifier(RemoteKeySurface(isSelected: true))
            Text("Disabled").frame(maxWidth: .infinity, minHeight: 44)
                .modifier(RemoteKeySurface()).disabled(true)
            HStack { ProgressView(); Text("Sending") }.frame(maxWidth: .infinity, minHeight: 44)
                .modifier(RemoteKeySurface())
        }
        .font(.body)
        .padding(24)
        .background(RemoteInstrument.canvas)
    }
}

/// Standalone preview of the reusable instrument control system: the two-key
/// AUTO/FULL bank, the THEME bank, and the 8-color accent bank, in both
/// appearances, so the industrial language can be QA'd without a session.
struct RemoteInstrumentFixture: View {
    @Environment(\.remoteAppearance) private var appearance
    @State private var mode = "AUTO"
    @State private var theme = "DARK"
    @State private var accentRaw = "graphite"

    /// QA knob: force an appearance for capture runs without touching the
    /// persisted user setting.
    private var appearanceOverride: RemoteAppearance? {
        guard let raw = ProcessInfo.processInfo.environment["VAMP_TEST_APPEARANCE"] else { return nil }
        return RemoteAppearance(rawValue: raw)
    }

    var body: some View {
        ZStack {
            RemoteBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VampMicroLabel(title: "INSTRUMENT KEYS")
                    VampMicroLabel(title: "AUTO / FULL")
                    InstrumentKeyBank(
                        selection: Binding(get: { mode }, set: { mode = $0 }),
                        titles: ["AUTO", "FULL"],
                        values: ["AUTO", "FULL"],
                        isMono: true,
                        size: .compact)
                    VampMicroLabel(title: "AUTO / FULL REGULAR")
                    InstrumentKeyBank(
                        selection: Binding(get: { mode }, set: { mode = $0 }),
                        titles: ["AUTO", "FULL"],
                        values: ["AUTO", "FULL"],
                        isMono: true)

                    VampMicroLabel(title: "THEME")
                    InstrumentKeyBank(
                        selection: Binding(get: { theme }, set: { theme = $0 }),
                        titles: ["SYSTEM", "LIGHT", "DARK"],
                        values: ["SYSTEM", "LIGHT", "DARK"],
                        isMono: true)

                    VampMicroLabel(title: "ACCENT")
                    InstrumentAccentBank(
                        selection: Binding(get: { accentRaw }, set: { accentRaw = $0 }),
                        palettes: AccentPalette.allCases.map(\.rawValue),
                        labels: AccentPalette.allCases.map(\.label),
                        colors: AccentPalette.allCases.map { palette in
                            let hex = palette.hexes.accentLight
                            return Color(red: Double((hex >> 16) & 0xFF) / 255,
                                         green: Double((hex >> 8) & 0xFF) / 255,
                                         blue: Double(hex & 0xFF) / 255)
                        })

                    VampMicroLabel(title: "ACTIONS")
                    InstrumentActionBank(actions: [
                        InstrumentAction(id: "bots", title: "Bots", symbol: "person.3", action: {}),
                        InstrumentAction(id: "control", title: "Control Mac", symbol: "display",
                                         secondary: "CONNECTED", ledColor: RemoteInstrument.green, action: {}),
                        InstrumentAction(id: "choose", title: "Computer",
                                         symbol: "desktopcomputer.and.macbook",
                                         secondary: "MAC STUDIO", action: {})
                    ])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            }
        }
        .environment(\.remoteAppearance, appearanceOverride ?? appearance)
        .preferredColorScheme(appearanceOverride?.colorScheme)
        .onAppear {
            let override = ProcessInfo.processInfo.environment["VAMP_INSTRUMENT_ACCENT"]
            if let override, AccentPalette.allCases.contains(where: { $0.rawValue == override }) {
                accentRaw = override
            }
        }
    }
}
#endif
