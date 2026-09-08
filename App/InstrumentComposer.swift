import AppKit
import SwiftUI

// MARK: - INSTRUMENT 01: the approved silver composer
//
// Reference: tmp/instrument/02_APPROVED_COMPOSER.png (1024 × 252 px).
// Documented pixel→point mapping: the chassis occupies ~1008 × 240 px of the
// crop (≈8px margins). The canonical desktop scale is 1080pt wide, so
// scale = 1080 / 1008 ≈ 1.071 pt/px, giving a chassis ≈ 1080 × 257pt; the
// brief's proposed 253pt height is used as the canonical chassis height and
// the original fixture establishes the material and right-endcap language.
// Production now shares a fixed 64pt left spine with navigation; the isolated
// fixture embeds the same hardware component. Controls use 44pt hit targets.
//
//   editor recess     = upper band, ~50% chassis height
//   lower faceplate   = lower ~39% chassis height
//   dial diameter     = ~17% chassis height            (≈44pt)
//   fasteners         = ~1.6% chassis height           (≈4pt)
//
// Every control is a real interactive view bound to production state
// (ComposerStore, AgentSessionController, AppState, SettingsStore). The
// reference image is never drawn as the interface.

enum Instrument {
    /// Test-only frame reporting for the visual acceptance checks. Enabled
    /// by `--design-preview`; the composer writes its global chassis frame
    /// to a temp file so measurement scripts can verify centering and the
    /// bottom gap without debug overlays in production.
    @MainActor static var debugFrameReport = false

    @MainActor static func reportFrame(_ frame: CGRect) {
        guard debugFrameReport else { return }
        let line = "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)\n"
        try? line.write(toFile: "/tmp/vamp-composer-frame.txt",
                        atomically: true, encoding: .utf8)
    }

    /// Approved chassis aspect (visible body, shadow excluded): 4.28155:1.
    static let referenceRatio: CGFloat = 4.281553398058253
    /// Canonical one-line height at a given width.
    static func canonicalHeight(for width: CGFloat) -> CGFloat {
        width / referenceRatio
    }

    /// Canonical chassis width at desktop scale.
    static let canonicalWidth: CGFloat = 1080
    /// Chassis height at canonical width (4.27:1 from the approved image).
    static let canonicalHeight: CGFloat = 253

    static var endcapFraction: CGFloat { 0.08 }
    static var faceplateFraction: CGFloat { 0.39 }

    // Sampled reference anchors (REFERENCE_GEOMETRY.json): neutral silver
    // editor area, endcap/faceplate region, dark inserts. Local shading and
    // edges complete the finish — these are anchors, not flat fills.
    static let silverTop = Color.dynamic(light: 0xDAD9D7, dark: 0x454545)
    static let silverMid = Color.dynamic(light: 0xD0CFCD, dark: 0x3B3B3B)
    static let silverLow = Color.dynamic(light: 0xC6C5C3, dark: 0x343434)
    static let faceplate = Color.dynamic(light: 0xCBCAC7, dark: 0x3A3A3A)
    static let silverEdgeDark = Color.dynamic(light: 0x949390, dark: 0x1E1E1E)
    static let recessFill = Color.dynamic(light: 0xD3D2D0, dark: 0x2B2B2B)
    /// The bright edge of raised controls, paired with their body material.
    static let controlHighlight = Color.dynamic(light: 0xF5F4F1, dark: 0x555555)
    static let seam = Color.black.opacity(0.18)
    static let seamLight = Color.dynamic(light: 0xFFFFFF, dark: 0x747474).opacity(0.6)
    static let engraved = Color.dynamic(light: 0x51534F, dark: 0xBDBDB8)
    static let darkInsert = Color(red: 0.141, green: 0.145, blue: 0.149)  // ≈ #242526
    static let sendFace = Color(red: 0.125, green: 0.133, blue: 0.137)    // ≈ #202223
    static let accentOrange = Color(red: 0.88, green: 0.48, blue: 0.18)
    static let signalGreen = Color(red: 0.34, green: 0.76, blue: 0.37)
    static let signalIdle = Color(red: 0.55, green: 0.55, blue: 0.55)
    /// Primary/secondary ink for text on silver surfaces.
    static let ink = Theme.textOnSilver
    static let inkSecondary = Theme.secondaryOnSilver
    static let signalBlue = Color.fixed(0x58A4D2)
    static let signalPurple = Color.fixed(0xB77ACE)

    /// Micro-label style: spaced uppercase technical text.
    static func microLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(engraved)
    }
}

// MARK: - Composer

struct InstrumentFasteners: View {
    var body: some View {
        VStack {
            HStack {
                fastener; Spacer(); fastener
            }
            Spacer()
            HStack {
                fastener; Spacer(); fastener
            }
        }
        .padding(7)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var fastener: some View {
        Circle()
            .fill(RadialGradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0.45)],
                                 center: .center, startRadius: 0, endRadius: 3))
            .frame(width: 4.5, height: 4.5)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
    }

}

struct ComposerDockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 224
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shared controls: production rail and standalone fixture use one implementation.
struct ComposerHardwareSpine: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AgentSessionController
    @State private var statusPopover = false
    @State private var activityPopover = false

    var body: some View {
        VStack(spacing: 0) {
            grille.padding(.top, 12).padding(.bottom, 8)
            ForEach(LeftControl.allCases) { control in
                leftControlButton(control)
            }
            Spacer(minLength: 0)
        }
        .frame(width: SidebarMetrics.collapsedWidth)
        .frame(maxHeight: .infinity)
        .overlay(InstrumentFasteners())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-hardware-spine")
    }

    private var grille: some View {
        // Perforated grille: 6 × 5 dot matrix, decorative only.
        VStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<6, id: \.self) { _ in
                        Circle()
                            .fill(Instrument.engraved.opacity(0.75))
                            .frame(width: 2.2, height: 2.2)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Left controls

    enum LeftControl: String, CaseIterable, Identifiable {
        case status, activity, stop, actions
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .status: "circle.fill"
            case .activity: "triangle.fill"
            case .stop: "square.fill"
            case .actions: "line.3.horizontal"
            }
        }

        var help: String {
            switch self {
            case .status: "Session status"
            case .activity: "Run activity"
            case .stop: "Stop the active run"
            case .actions: "Conversation actions"
            }
        }
    }

    private func leftControlButton(_ control: LeftControl) -> some View {
        Button {
            activate(control)
        } label: {
            Image(systemName: control.symbol)
                .font(.system(size: control == .actions ? 11 : 10, weight: .medium))
                .foregroundStyle(Instrument.ink.opacity(0.88))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        LinearGradient(colors: [Instrument.controlHighlight,
                                                Instrument.silverTop,
                                                Instrument.silverMid],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(Circle().strokeBorder(Instrument.seam.opacity(0.55), lineWidth: 0.75))
                .overlay(alignment: .top) {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 0.75)
                        .padding(1)
                        .opacity(0.6)
                }
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(InstrumentPressStyle())
        .disabled(control == .stop && !controller.isRunning)
        .opacity(control == .stop && !controller.isRunning ? 0.8 : 1)
        .popover(isPresented: binding(for: control)) {
            popoverContent(for: control)
        }
        .help(control.help)
        .accessibilityLabel(control.help)
    }

    private func binding(for control: LeftControl) -> Binding<Bool> {
        switch control {
        case .status: return $statusPopover
        case .activity: return $activityPopover
        default: return .constant(false)
        }
    }

    private func activate(_ control: LeftControl) {
        switch control {
        case .status: statusPopover = true
        case .activity: activityPopover = true
        case .stop: controller.stop()
        case .actions:
            NotificationCenter.default.post(name: .exportChatMarkdown, object: nil)
        }
    }

    @ViewBuilder
    private func popoverContent(for control: LeftControl) -> some View {
        switch control {
        case .status:
            VStack(alignment: .leading, spacing: 6) {
                Text("Session status").font(.system(size: 12, weight: .semibold))
                Text(statusSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 240)
        case .activity:
            VStack(alignment: .leading, spacing: 6) {
                Text("Run activity").font(.system(size: 12, weight: .semibold))
                Text(activitySummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 260)
        default:
            EmptyView()
        }
    }

    private var statusSummary: String {
        let model = appState.statusModelLabel
        let phase = controller.isRunning ? "running" : "idle"
        return "Model: \(model)\nPhase: \(phase)\nWorkspace: \(controller.workspaceURL?.lastPathComponent ?? "none")"
    }

    private var activitySummary: String {
        let calls = controller.transcript.compactMap { item -> String? in
            if case .toolCall(let invocation) = item.kind { return invocation.name }
            return nil
        }
        guard !calls.isEmpty else { return "No tool activity in this conversation." }
        let counts = Dictionary(grouping: calls, by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: "\n")
    }


}

struct InstrumentComposer: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AgentSessionController
    @ObservedObject private var settings = SettingsStore.shared
    var store: ComposerStore
    @FocusState private var editorFocused: Bool

    /// Welcome shows the separate suggestion row; conversation docks tight.
    var placement: Placement = .conversation
    enum Placement { case welcome, conversation }

    let embeddedInRail: Bool

    init(store: ComposerStore, placement: Placement = .conversation, embeddedInRail: Bool = false) {
        self.store = store
        self.placement = placement
        self.embeddedInRail = embeddedInRail
    }

    var body: some View {
        chassis
    }

    /// Measured chassis width; the height derives from it (reference ratio)
    /// plus deterministic growth for multiline drafts and attachments.
    @State private var measuredWidth: CGFloat = Instrument.canonicalWidth

    /// Estimated wrapped lines of the current draft at the editor width.
    private var draftLines: Int {
        let charsPerLine = max(20, Int((measuredWidth * 0.82) / 9))
        var lines = 0
        for paragraph in store.prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, Int(ceil(Double(paragraph.count) / Double(charsPerLine))))
        }
        return max(1, lines)
    }

    private var extraHeight: CGFloat {
        let extraLines = max(0, draftLines - 1)
        let attachmentLane = store.attachments.isEmpty ? 0 : 30
        return CGFloat(min(extraLines, 5)) * 24 + CGFloat(attachmentLane)
    }

    private var chassisHeight: CGFloat {
        max(224, min(253, Instrument.canonicalHeight(for: measuredWidth))) + extraHeight
            + (compactControls ? 44 : 0)
    }

    private var compactControls: Bool {
        measuredWidth - (embeddedInRail ? 0 : SidebarMetrics.collapsedWidth)
            - (measuredWidth < 700 ? 58 : 72) - 8 < 620
    }

    // MARK: Chassis
    //
    // Geometry derives from REFERENCE_GEOMETRY.json (visible chassis,
    // shadow excluded): ratio 4.28155:1; left endcap 7.71% of width; right
    // endcap 7.86%; editor 9.07%→90.97% of width, top 6.47%, height 50.8%;
    // lower strip from 61.2% of height (38.8% tall); selector faces 16.5%
    // of height. The normal one-line height follows the ratio; multiline
    // drafts, attachments, and larger text grow it deterministically.

    private var chassis: some View {
        GeometryReader { proxy in
            let w = measuredWidth
            let h = chassisHeight
            let rightCap: CGFloat = w < 700 ? 58 : 72
            let stripH: CGFloat = compactControls ? 128 : 84
            let editorH = h - stripH - 18

            ZStack(alignment: .topLeading) {
                chassisBody
                HStack(spacing: 0) {
                    if !embeddedInRail {
                        ComposerHardwareSpine()
                            .overlay(alignment: .trailing) { seamLine }
                    }
                    centerRegion(editorHeight: editorH, stripHeight: stripH)
                    rightEndcap(width: rightCap)
                }
            }
            .frame(width: w, height: h)
        }
        .frame(height: chassisHeight)
        .preference(key: ComposerDockHeightKey.self, value: embeddedInRail ? chassisHeight : 224)
        .background {
            GeometryReader { probe in
                Color.clear
                    .onChange(of: probe.frame(in: .global), initial: true) { _, frame in
                        measuredWidth = frame.width
                        Instrument.reportFrame(frame)
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composer")
    }

    private var chassisBody: some View {
        chassisShape
            .fill(
                LinearGradient(colors: [Instrument.silverTop, Instrument.silverMid, Instrument.silverLow],
                               startPoint: .top, endPoint: .bottom))
            // Fine bright upper edge, darker lower edge.
            .overlay(
                chassisShape
                    .strokeBorder(
                        LinearGradient(colors: [Instrument.seamLight,
                                                Instrument.seam.opacity(0.5),
                                                Instrument.silverEdgeDark],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
            .overlay(grainOverlay)
            .shadow(color: .black.opacity(embeddedInRail ? 0 : 0.38), radius: 8, y: 5)
    }

    private var chassisShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: embeddedInRail ? 0 : 9,
                               bottomLeadingRadius: embeddedInRail ? 0 : 9,
                               bottomTrailingRadius: 9, topTrailingRadius: 9)
    }

    /// Cached fine grain: generated once into a tiny NSImage and tiled by
    /// ImagePaint. No per-frame randomness, no per-token recomputation.
    private var grainOverlay: some View {
        chassisShape
            .fill(ImagePaint(image: Image(nsImage: Self.grainImage), scale: 1))
            .opacity(0.06)
            .allowsHitTesting(false)
    }

    static let grainImage: NSImage = {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            seed &+= 0x6D2B79F5
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z % 1000) / 1000.0
        }
        for _ in 0..<420 {
            let x = next() * 64
            let y = next() * 64
            let dark = next() > 0.5
            let alpha = 0.25 + next() * 0.35
            let color: NSColor = dark
                ? NSColor(white: 0, alpha: alpha)
                : NSColor(white: 1, alpha: alpha * 0.8)
            color.setFill()
            NSRect(x: x, y: y, width: 1, height: 1).fill()
        }
        image.unlockFocus()
        return image
    }()

    // MARK: Endcaps

    private func rightEndcap(width: CGFloat) -> some View {
        VStack(spacing: 10) {
            dial
                .padding(.top, 16)
            indicatorBank
            Spacer(minLength: 0)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) { seamLine }
        .overlay(InstrumentFasteners())
    }

    private var seamLine: some View {
        Rectangle()
            .fill(
                LinearGradient(colors: [Instrument.seamLight.opacity(0.7), Instrument.seam],
                               startPoint: .leading, endPoint: .trailing))
            .frame(width: 1)
            .padding(.vertical, 6)
    }

    // MARK: Center

    private func centerRegion(editorHeight: CGFloat, stripHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            editorRecess
                .frame(height: editorHeight, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            faceplate(height: stripHeight)
        }
    }

    private var editorRecess: some View {
        ZStack(alignment: .topLeading) {
            // Shallow recessed cavity: defined upper/side inset edge, faint
            // lower highlight, calm readable interior.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Instrument.recessFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(editorFocused ? Instrument.ink.opacity(0.7) : Instrument.seam.opacity(0.7),
                                      lineWidth: editorFocused ? 1.5 : 1))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(height: 1)
                        .padding(.horizontal, 6)
                }

            VStack(spacing: 6) {
                if !store.attachments.isEmpty {
                    attachmentLane
                }
                ZStack(alignment: .topLeading) {
                    if store.prompt.isEmpty {
                        // AppKit can re-template TextField's native prompt in
                        // Dark appearance, turning it pale on a fixed silver
                        // surface. A separate inert label keeps the approved
                        // dark placeholder in both appearances.
                        Text("What's on your mind?")
                            .font(.appUI(size: 18))
                            .foregroundStyle(Theme.placeholderOnSilver)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: Bindable(store).prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .font(.appUI(size: 18))
                        .foregroundStyle(Instrument.ink)
                        .accessibilityLabel("Task description")
                        .focused($editorFocused)
                        .onKeyPress(phases: .down) { press in
                            if press.key == .escape && controller.isRunning {
                                controller.stop()
                                return .handled
                            }
                            if press.key == .return,
                               let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                                if editor.hasMarkedText() { return .ignored }
                                if press.modifiers == .shift || press.modifiers == .option
                                    || (press.modifiers.isEmpty && !settings.enterSends) {
                                    editor.insertNewlineIgnoringFieldEditor(nil)
                                    return .handled
                                }
                            }
                            if ShortcutBinding(rawValue: settings.sendShortcut).matches(press) {
                                _ = store.submit()
                                return .handled
                            }
                            if press.key == .return && press.modifiers.contains(.command) {
                                _ = store.submit()
                                return .handled
                            }
                            if press.key == .return && press.modifiers.isEmpty && settings.enterSends {
                                // A send attempt must not fall through to a newline when
                                // the model is unavailable or the current draft is empty.
                                _ = store.submit()
                                return .handled
                            }
                            return .ignored
                        }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    if measuredWidth >= 900 {
                      Text(settings.enterSends ? "↩ to send · ⇧↩ for newline"
                           : "\(ShortcutBinding(rawValue: settings.sendShortcut).displayValue) to send")
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.engraved)
                        .padding(.trailing, 12)
                    }
                    sendButton
                        .padding(.trailing, 14)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    /// Attachments occupy their own lane at the top of the recess so they
    /// never cover the draft or the send control.
    private var attachmentLane: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.attachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.isImage ? "photo" : "doc.text")
                            .font(.system(size: 9, weight: .medium))
                        Text(attachment.name)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                        Button {
                            store.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .foregroundStyle(Instrument.engraved)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.black.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Instrument.seam.opacity(0.5), lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 24)
    }

    private var sendButton: some View {
        Button {
            if controller.isRunning { controller.stop() } else { store.send() }
        } label: {
            Image(systemName: controller.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(
                    Circle().fill(
                        RadialGradient(colors: [Instrument.sendFace.opacity(0.92),
                                                Instrument.sendFace],
                                       center: .init(x: 0.4, y: 0.35),
                                       startRadius: 4, endRadius: 30)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
        }
        .buttonStyle(InstrumentPressStyle())
        .disabled(!controller.isRunning && !store.canSend)
        .opacity(!controller.isRunning && !store.canSend ? 0.5 : 1)
        .help(controller.isRunning ? "Stop (Esc)" : "Send")
        .accessibilityLabel(controller.isRunning ? "Stop" : "Send")
    }

    // MARK: Faceplate
    //
    // One integrated lower faceplate whose modules have deliberate intrinsic
    // ranges. The model lane receives the most room, utilities remain a
    // compact cluster, and surplus width is absorbed by the three selectors
    // instead of becoming an empty strip.

    private func faceplate(height: CGFloat) -> some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let normalGrid = w >= 760
            let toolsWidth: CGFloat = normalGrid ? 135 : 116
            let modeWidth: CGFloat = normalGrid ? 170 : 130
            let micWidth: CGFloat = normalGrid ? 65 : 52
            let utilityWidth: CGFloat = normalGrid ? 168 : 156
            // The model is the only elastic selector. Tools/mode retain
            // intrinsic-sized bays and utilities never become stretched keys.
            let modelWidth = max(140, w - toolsWidth - modeWidth - micWidth - utilityWidth - 19)
            if w < 620 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        module(label: "MODEL", width: w * 0.55) { modelCapsule }
                            .overlay(alignment: .trailing) { cellSeam }
                        module(label: "TOOLS", width: w * 0.45) { toolsCapsule }
                    }
                    HStack(spacing: 0) {
                        module(label: "ASSISTANT", width: w - 112) { assistantCapsule }
                            .overlay(alignment: .trailing) { cellSeam }
                        Menu {
                            Button("Browser tools", systemImage: "globe") {
                                NotificationCenter.default.post(name: .toggleBrowserPanel, object: nil)
                            }
                            Button("Attach files", systemImage: "doc") { attachFiles() }
                            Button("Open project", systemImage: "folder") {
                                NotificationCenter.default.post(name: .openWorkspace, object: nil)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 40, height: 34)
                                .foregroundStyle(Instrument.ink)
                                .instrumentRecess(radius: 6)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 56)
                        .accessibilityLabel("Composer utilities")
                        .help("Browser, attachments, and project")
                        micCell.frame(width: 56)
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .leading) { cellSeam }
                    }
                }
                .frame(width: w, height: height)
            } else {
              HStack(spacing: 0) {
                module(label: "MODEL", width: modelWidth) { modelCapsule }
                cellSeam
                module(label: "TOOLS", width: toolsWidth) { toolsCapsule }
                cellSeam
                module(label: "ASSISTANT", width: modeWidth) { assistantCapsule }
                cellSeam
                HStack(spacing: 0) {
                    utilityCell("globe", help: "Browser tools") {
                        NotificationCenter.default.post(name: .toggleBrowserPanel, object: nil)
                    }
                    utilityCell("doc", help: "Attach files") { attachFiles() }
                        .overlay(alignment: .leading) { cellSeam }
                    utilityCell("folder", help: "Open project") {
                        NotificationCenter.default.post(name: .openWorkspace, object: nil)
                    }
                    .overlay(alignment: .leading) { cellSeam }
                }
                .frame(width: utilityWidth)
                .padding(.horizontal, 8)
                cellSeam
                micCell
                    .frame(width: micWidth)
            }
            .frame(width: w, height: height)
            }
        }
        .frame(height: height)
        .overlay(alignment: .top) {
            InstrumentDeckGroove(horizontal: true)
                .frame(height: 2)
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private var cellSeam: some View {
        InstrumentDeckGroove()
            .frame(width: 0.75)
            .padding(.vertical, 6)
    }

    private func module<Content: View>(label: String, width: CGFloat,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Instrument.microLabel(label)
                .padding(.leading, 8)
            content()
                .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .frame(width: width)
        .padding(.top, 7)
    }

    private func utilityCell(_ symbol: String, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Instrument.ink.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Instrument.controlHighlight, Instrument.recessFill],
                            startPoint: .top,
                            endPoint: .bottom)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Instrument.silverEdgeDark.opacity(0.65), lineWidth: 0.75))
                .overlay(alignment: .top) {
                    InstrumentDeckGroove(horizontal: true)
                        .frame(height: 2)
                        .padding(.horizontal, 5)
                        .padding(.top, 1)
                }
                .shadow(color: .black.opacity(0.14), radius: 0.5, y: 1)
        }
        .buttonStyle(InstrumentUtilityKeyStyle())
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .help(help)
        .accessibilityLabel(help)
    }

    private var micCell: some View {
        Button {} label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Instrument.ink.opacity(0.85))
                .frame(width: 46, height: 46)
                .background(
                    Circle().fill(LinearGradient(colors: [Instrument.controlHighlight,
                                                          Instrument.recessFill],
                                                 startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(Instrument.seam.opacity(0.6), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
        }
        .buttonStyle(InstrumentPressStyle())
        .disabled(true)
        .help("Voice input is not available in this build")
        .accessibilityLabel("Voice input (unavailable)")
    }

    // MARK: Capsules

    private var modelCapsule: some View {
        InstrumentMenu(menuWidth: 260) {
            capsuleLabel(
                leading: Circle().fill(Instrument.ink).frame(width: 7, height: 7),
                text: modelName,
                dark: false)
        } options: {
            ForEach(appState.modelStore.installed) { installed in
                InstrumentMenuRow(
                    title: ModelCatalog.model(id: installed.id)?.displayName ?? installed.id,
                    systemImage: "cpu",
                    isSelected: appState.statusModelLabel == (ModelCatalog.model(id: installed.id)?.displayName ?? installed.id)) {
                    if let catalog = ModelCatalog.model(id: installed.id) {
                        Task { await appState.activate(model: catalog) }
                    }
                }
            }
            InstrumentMenuRow(title: "Model library…", systemImage: "shippingbox") {
                NotificationCenter.default.post(name: .openModelManager, object: nil)
            }
        }
        .help("Model: \(modelName)")
        .accessibilityLabel("Model: \(modelName)")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelName: String {
        let label = appState.statusModelLabel
        if label.isEmpty || label == "No model" { return "Choose model" }
        return label
    }

    private var toolsCapsule: some View {
        InstrumentMenu(menuWidth: 240) {
            capsuleLabel(
                leading: HStack(spacing: 3) {
                    Image(systemName: "command")
                        .font(.system(size: 9, weight: .semibold))
                    Circle().fill(Instrument.accentOrange).frame(width: 5, height: 5)
                },
                text: "Tools",
                dark: false)
        } options: {
            InstrumentMenuRow(
                title: settings.computerControlEnabled ? "Disable Mac control" : "Enable Mac control",
                systemImage: "laptopcomputer.and.arrow") {
                settings.computerControlEnabled.toggle()
            }
            InstrumentMenuRow(title: "Browser panel", systemImage: "globe") {
                NotificationCenter.default.post(name: .toggleBrowserPanel, object: nil)
            }
        }
        .help("Tool configuration")
        .accessibilityLabel("Tools")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantCapsule: some View {
        InstrumentMenu(menuWidth: 220) {
            capsuleLabel(
                leading: Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .semibold)),
                text: settings.agentMode.label,
                dark: true)
        } options: {
            ForEach(AgentMode.allCases) { mode in
                InstrumentMenuRow(
                    title: mode.label,
                    systemImage: mode.icon,
                    isSelected: settings.agentMode == mode) {
                    settings.agentMode = mode
                }
            }
        }
        .help("Assistant mode: \(settings.agentMode.label)")
        .accessibilityLabel("Assistant mode")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capsuleLabel(leading: some View, text: String, dark: Bool) -> some View {
        HStack(spacing: 5) {
            leading
            Text(text)
                .font(.system(size: 13.5, weight: dark ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .opacity(dark ? 0.9 : 0.6)
        }
        .foregroundStyle(dark ? Color.white : Instrument.ink)
        .padding(.horizontal, 9)
        .frame(height: 37)
        .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule().fill(dark
                           ? AnyShapeStyle(LinearGradient(
                                colors: [Instrument.darkInsert.opacity(0.94),
                                         Instrument.darkInsert],
                                startPoint: .top, endPoint: .bottom))
                           : AnyShapeStyle(LinearGradient(
                                colors: [Instrument.controlHighlight, Instrument.recessFill],
                                startPoint: .top, endPoint: .bottom))))
        .overlay(Capsule().strokeBorder(
            dark ? Color.white.opacity(0.10) : Instrument.seam.opacity(0.65),
            lineWidth: 0.75))
        .shadow(color: dark ? .clear : Color.black.opacity(0.10), radius: 1, y: 1)
        .contentShape(Capsule())
    }

    // MARK: Dial + indicators

    /// Raised circular cap: narrow barrel/rim, localized contact shadow, and
    /// an orange index marker. Bound to the real Response style setting with
    /// menu + keyboard access (drag is not the only input).
    private var dial: some View {
        InstrumentMenu(menuWidth: 220) {
            ZStack {
                // Barrel/rim: darker ring beneath the cap.
                Circle()
                    .fill(LinearGradient(colors: [Instrument.silverEdgeDark,
                                                  Instrument.silverLow],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 54, height: 54)
                // Raised cap with upper-left lighting.
                Circle()
                    .fill(LinearGradient(colors: [Instrument.controlHighlight,
                                                  Instrument.silverTop,
                                                  Instrument.silverMid],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 48, height: 48)
                    .overlay(Circle().strokeBorder(Instrument.seam.opacity(0.5), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
                // Index marker.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Instrument.accentOrange)
                    .frame(width: 3, height: 9)
                    .offset(y: 15)
                    .rotationEffect(.degrees(settings.outputStyle == .concise ? -45
                                             : settings.outputStyle == .detailed ? 45 : 0))
            }
            .frame(width: 54, height: 54)
        } options: {
            ForEach(ProjectPolicy.OutputStyle.allCases) { style in
                InstrumentMenuRow(
                    title: style.label,
                    systemImage: "circle",
                    isSelected: settings.outputStyle == style) {
                    settings.outputStyle = style
                }
            }
        }
        .help("Response style: \(settings.outputStyle.label)")
        .accessibilityLabel("Response style dial: \(settings.outputStyle.label)")
    }

    private var indicatorBank: some View {
        VStack(alignment: .leading, spacing: 7) {
            indicator("READY", on: store.canSend || controller.isRunning)
            indicator("WEB", on: true)
            indicator("FILES", on: controller.workspaceURL != nil)
            indicator("MAC", on: settings.computerControlEnabled)
        }
        .padding(.leading, 12)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
    }

    private func indicator(_ label: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            InstrumentLiveSignal(active: on)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Instrument.engraved)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityLabel("\(label): \(on ? "available" : "inactive")")
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        store.addAttachments(panel.urls)
    }
}

// MARK: - Press style

/// Adjacent, pixel-aligned dark/highlight cuts; decorative and layout-neutral.
private struct InstrumentDeckGroove: View {
    var horizontal = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let scale = max(1, displayScale)
            let pixel = 1 / scale
            let origin = proxy.frame(in: .global).origin
            Canvas { context, size in
                let x = (origin.x * scale).rounded() / scale - origin.x
                let y = (origin.y * scale).rounded() / scale - origin.y
                let cut = CGRect(x: x, y: y,
                                 width: horizontal ? size.width : pixel,
                                 height: horizontal ? pixel : size.height)
                context.fill(Path(cut), with: .color(.black.opacity(colorScheme == .dark ? 0.40 : 0.18)))
                context.fill(Path(cut.offsetBy(dx: horizontal ? 0 : pixel,
                                                dy: horizontal ? pixel : 0)),
                             with: .color(.white.opacity(colorScheme == .dark ? 0.09 : 0.40)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct InstrumentUtilityKeyStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.07 : (hovering ? 0.035 : 0))
            .offset(y: configuration.isPressed ? 1 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct InstrumentPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10),
                       value: configuration.isPressed)
    }
}

// MARK: - Suggestion row

struct SuggestionRow: View {
    var store: ComposerStore
    var availableWidth: CGFloat
    @State private var rotation = 0

    init(store: ComposerStore, availableWidth: CGFloat = 1000) {
        self.store = store
        self.availableWidth = availableWidth
    }

    private struct Suggestion: Identifiable {
        var id: String { text }
        let marker: Color
        let text: String
        let draft: String
    }

    private var suggestions: [Suggestion] {
        let all: [Suggestion] = [
            .init(marker: Instrument.signalGreen, text: "Summarize this page", draft: "Summarize the current page."),
            .init(marker: Instrument.signalBlue, text: "Write a doc", draft: "Draft a document about "),
            .init(marker: Instrument.accentOrange, text: "Search the web", draft: "Search the web for "),
            .init(marker: Instrument.signalPurple, text: "Open a project", draft: ""),
            .init(marker: Instrument.signalIdle, text: "Analyze files", draft: "Analyze the files in "),
        ]
        let r = rotation % all.count
        return Array(all[r...] + all[..<r])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRY SOMETHING")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.secondaryOnSilver)
            HStack(spacing: 10) {
                ForEach(suggestions.prefix(max(1, min(5, Int((availableWidth - 100) / 190))))) { suggestion in
                    Button {
                        select(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(suggestion.marker).frame(width: 6, height: 6)
                            Text(suggestion.text)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textOnControlInsert)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Theme.textOnControlInsert.opacity(0.6))
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(Theme.controlInsert))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75))
                    }
                    .buttonStyle(InstrumentPressStyle())
                    .accessibilityLabel(suggestion.text)
                }
                Button { rotation += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textOnControlInsert.opacity(0.7))
                        .frame(width: 34, height: 34)
                        .background(Capsule().fill(Theme.controlInsert))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75))
                }
                .buttonStyle(InstrumentPressStyle())
                .help("Refresh suggestions")
                .accessibilityLabel("Refresh suggestions")
            }
        }
    }

    private func select(_ suggestion: Suggestion) {
        if suggestion.text == "Open a project" {
            NotificationCenter.default.post(name: .openWorkspace, object: nil)
            return
        }
        store.prompt = suggestion.draft
    }
}

/// Small, isolated animation surface; never invalidates the composer or its editor.
struct InstrumentLiveSignal: View {
    let active: Bool
    var bars = false
    var tint: Color = Instrument.signalGreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let animates = active && !reduceMotion && scenePhase == .active
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animates)) { context in
            let time = animates ? context.date.timeIntervalSinceReferenceDate : 0
            let breath = animates ? (sin(time * 2.1) + 1) / 2 : 1
            let color = active ? tint : Instrument.signalIdle
            if bars {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<4) { index in
                        Capsule()
                            .fill(color.opacity(active ? 0.8 : 0.5))
                            .frame(width: 2, height: animates
                                   ? 4 + 7 * (sin(time * 2.4 + Double(index) * 0.9) + 1) / 2
                                   : 5)
                    }
                }
                .frame(width: 14, height: 12)
            } else {
                Circle()
                    .fill(color)
                    .opacity(active ? 0.6 + 0.4 * breath : 1)
                    .shadow(color: color.opacity(active ? 0.3 * breath : 0), radius: 3)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
