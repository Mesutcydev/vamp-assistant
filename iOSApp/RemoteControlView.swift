import SwiftUI
import UIKit

enum RemoteControlSourceMode {
    case display
    case application
}

private struct RemoteControlUnavailableState: View {
    @Environment(\.remoteAppearance) private var appearance
    let title: String
    let message: String
    let status: String
    let symbol: String
    let isWorking: Bool
    let topInset: CGFloat
    let bottomInset: CGFloat
    let primaryTitle: String?
    let primaryAction: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image("WindowAtmosphere")
                    .resizable()
                    .scaledToFill()
                    .saturation(0)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay(appearance == .light
                        ? Color.white.opacity(0.58)
                        : Color.black.opacity(0.46))
                    .overlay {
                        LinearGradient(
                            colors: appearance == .light
                                ? [.white.opacity(0.18), .white.opacity(0.62)]
                                : [.black.opacity(0.02), .black.opacity(0.40)],
                            startPoint: .top,
                            endPoint: .bottom)
                    }
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                HStack {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial, in: Circle())
                            .overlay(Circle().stroke(BeetTheme.line(appearance), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close remote control")
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, max(topInset + 8, 58))

                Spacer(minLength: 28)

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(BeetTheme.surfaceStrong(appearance))
                            .frame(width: 76, height: 76)
                        Circle()
                            .stroke(BeetTheme.line(appearance), lineWidth: 0.75)
                            .frame(width: 76, height: 76)
                        if isWorking {
                            ProgressView().controlSize(.large).tint(BeetTheme.accentBright)
                        } else {
                            Image(systemName: symbol)
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(BeetTheme.accentBright)
                        }
                    }

                    VStack(spacing: 8) {
                        Text(status)
                            .font(.caption2.weight(.bold))
                            .tracking(1.1)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .frame(maxWidth: 330)
                    }

                    VStack(spacing: 10) {
                        if let primaryTitle, let primaryAction {
                            Button(action: primaryAction) {
                                Label(primaryTitle, systemImage: "arrow.clockwise")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(white: 0.28))
                            .disabled(isWorking)
                        }
                        Button("Back to Vamp Assistant", action: dismiss)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.76))
                            .frame(minHeight: 44)
                    }
                }
                    .frame(maxWidth: 340)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.22), .white.opacity(0.07)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing),
                                lineWidth: 0.75)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 28, y: 16)
                    .padding(.horizontal, 20)

                    Spacer(minLength: max(bottomInset, 16) + 20)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .ignoresSafeArea()
    }
}

struct RemoteControlView: View {
    let store: RemoteStore
    let sourceMode: RemoteControlSourceMode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var status: RemoteMacControlStatus?
    @State private var frame: RemoteMacControlFrame?
    @State private var errorText: String?
    @State private var reconnectBanner: String?
    @State private var showKeyboard = false
    @State private var keyboardPad: CGFloat = 0
    @State private var hideChrome = false
    @AppStorage("beet.remote.fillScreen") private var fillScreen = false
    @AppStorage("beet.remote.streamResolution") private var streamResolutionRaw = "1080p"
    @State private var dragLocked = false
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var previewZoom: CGFloat = 1
    @State private var previewOffset: CGSize = .zero
    @State private var lastPreviewPinch: CGFloat = 1
    @State private var lastPreviewDrag: CGSize = .zero
    @StateObject private var inputSender: RemoteInputSender
    @StateObject private var audioPlayer = RemoteAudioPlayer()
    @StateObject private var videoBinder = RemoteVideoSurfaceBinder()
    @StateObject private var streamRestart = RemoteStreamRestart()
    @StateObject private var markup = RemoteMarkupStore()
    @ObservedObject private var diagnostics = RemoteControlDiagnostics.shared
    @State private var decoder = RemoteH264Decoder()
    @State private var audioTask: Task<Void, Never>?
    @State private var showTerminal = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var selectedDisplayID: Int?
    @State private var applications: [RemoteMacApplication] = []
    @State private var selectedWindowID: Int?
    @State private var showStats = true
    @State private var fpsText = "—"
    @State private var bitrateText = "—"
    @State private var latencyText = "—"
    @State private var screenLatencyText = "—"
    @State private var lastFrameAt: Date?
    @State private var lastFrameBytes = 0
    @State private var screenshotStatus = ""
    @State private var reconnectAttempt = 0

    private var streamGeneration: Int { streamRestart.generation }
    private var isControlAvailable: Bool { store.isConnected && status?.ready != false }

    private var streamResolution: RemoteStreamResolution { RemoteStreamResolution.resolve(streamResolutionRaw) }
    private var activeDisplayID: UInt32? {
        sourceMode == .display ? selectedDisplayID.map(UInt32.init) : nil
    }
    private var activeWindowID: UInt32? {
        sourceMode == .application ? selectedWindowID.map(UInt32.init) : nil
    }
    private var selectedApplication: RemoteMacApplication? {
        guard let selectedWindowID else { return nil }
        return applications.first { $0.windowID == selectedWindowID }
    }
    private static let accent = Color(white: 0.72)
    private static let panel = Color(white: 0.10)

    init(store: RemoteStore, sourceMode: RemoteControlSourceMode = .display) {
        self.store = store
        self.sourceMode = sourceMode
        _inputSender = StateObject(wrappedValue: RemoteInputSender(sendCommands: { commands in
            _ = try await store.sendMacControlBatch(commands)
        }))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if !store.isConnected {
                    RemoteControlUnavailableState(
                        title: "Mac unavailable",
                        message: store.connectionSubtitle,
                        status: store.isConnecting ? "RECONNECTING" : "CONNECTION LOST",
                        symbol: "wifi.exclamationmark",
                        isWorking: store.isConnecting,
                        topInset: proxy.safeAreaInsets.top,
                        bottomInset: proxy.safeAreaInsets.bottom,
                        primaryTitle: "Reconnect",
                        primaryAction: { Task { await store.connectSaved() } },
                        dismiss: { dismiss() })
                } else if let status, !status.ready {
                    RemoteControlUnavailableState(
                        title: "Mac Control is off",
                        message: status.message ?? "Turn on Mac Control in Vamp Assistant on your Mac, then allow Screen Recording and Accessibility.",
                        status: "ACTION REQUIRED ON MAC",
                        symbol: "display.trianglebadge.exclamationmark",
                        isWorking: false,
                        topInset: proxy.safeAreaInsets.top,
                        bottomInset: proxy.safeAreaInsets.bottom,
                        primaryTitle: nil,
                        primaryAction: nil,
                        dismiss: { dismiss() })
                } else {
                    // Always mount the video layer once Control is reachable so decoded
                    // frames are not dropped while "Connecting…" is on screen.
                    ZStack {
                        inputSurface(frame: frame, size: proxy.size)
                        if !videoBinder.hasFrame {
                            ProgressView(frame == nil ? "Connecting to Mac…" : "Starting video…")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

                if isControlAvailable && markup.isVisible {
                    RemoteMarkupOverlay(store: markup)
                }

                if isControlAvailable && showStats {
                    statsHUD
                }

                if isControlAvailable, let reconnectBanner {
                    VStack {
                        Text(reconnectBanner)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.orange.opacity(0.85), in: Capsule())
                            .padding(.top, max(proxy.safeAreaInsets.top, 12) + 8)
                        Spacer()
                    }
                }

                if isControlAvailable && dragLocked {
                    VStack {
                        Text("drag lock")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Self.accent, in: Capsule())
                            .padding(.top, max(proxy.safeAreaInsets.top, 12) + (reconnectBanner == nil ? 8 : 44))
                        Spacer()
                    }
                }

                if isControlAvailable, let errorText {
                    VStack {
                        Spacer()
                        Text(errorText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.72), in: Capsule())
                            .padding(.bottom, max(proxy.safeAreaInsets.bottom, 10) + 72)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if !isControlAvailable {
                    EmptyView()
                } else if showKeyboard {
                    RemoteKeyboardOverlay(
                        sendText: { enqueue(.type($0)) },
                        sendKey: { key, modifiers in enqueue(.key(key, modifiers: modifiers)) },
                        onDismiss: { showKeyboard = false }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, keyboardPad)
                } else if hideChrome {
                    revealButton(bottomInset: max(proxy.safeAreaInsets.bottom, 10))
                } else {
                    classicBottomChrome(bottomInset: max(proxy.safeAreaInsets.bottom, 10))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .statusBarHidden(hideChrome)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showKeyboard)
        .sheet(isPresented: $showShare) {
            ActivityShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showTerminal) {
            RemoteTerminalView(store: store)
        }
        .task {
            configureDecoder()
            startAudio()
            await run()
        }
        .onChange(of: streamResolution) { _, _ in
            decoder.reset()
            videoBinder.reset()
            streamRestart.bump()
        }
        .onChange(of: selectedDisplayID) { _, _ in
            decoder.reset()
            videoBinder.reset()
            streamRestart.bump()
        }
        .onChange(of: selectedWindowID) { _, _ in
            decoder.reset()
            videoBinder.reset()
            resetZoom()
            streamRestart.bump()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillChangeFrameNotification)) { note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardPad = max(0, UIScreen.main.bounds.height - end.origin.y)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.keyboardWillHideNotification)) { _ in
            keyboardPad = 0
        }
        .onDisappear {
            audioTask?.cancel()
            audioTask = nil
            audioPlayer.stop()
            decoder.reset()
            videoBinder.reset()
            inputSender.stop(flushing: dragLocked ? .up(button: "left") : nil)
            dragLocked = false
        }
    }

    @ViewBuilder
    private func inputSurface(frame: RemoteMacControlFrame?, size: CGSize) -> some View {
        gestureScreen(frame: frame, size: size)
    }

    @ViewBuilder
    private func gestureScreen(frame: RemoteMacControlFrame?, size: CGSize) -> some View {
        GeometryReader { geo in
            let imageSize = CGSize(
                width: max(frame?.imageWidth ?? 1, 1),
                height: max(frame?.imageHeight ?? 1, 1))
            // Vamp Gestures: video is full-bleed; AVLayer gravity letterboxes inside the view.
            // Mapping uses the same content rect the gravity produces.
            let placed = RemoteDisplayMapping.contentRect(
                imageSize: imageSize,
                in: geo.size,
                mode: fillScreen ? .fill : .fit)
            RemoteVideoSurface(binder: videoBinder, fill: fillScreen)
                .scaleEffect(zoom, anchor: .center)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.9), value: zoom)
                .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.9), value: offset)

            if let frame {
            RemoteScreenGestureSurface(
                zoom: zoom,
                offset: offset,
                viewSize: geo.size,
                onTap: { point in
                    guard let mappedPoint = mapped(point, placed: placed, frame: frame) else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    enqueue(.click(x: mappedPoint.x, y: mappedPoint.y, button: "left", count: 1))
                },
                onDoubleTap: { point in
                    guard let mappedPoint = mapped(point, placed: placed, frame: frame) else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    enqueue(.click(x: mappedPoint.x, y: mappedPoint.y, button: "left", count: 2))
                },
                onRightClick: { point in
                    guard let mappedPoint = mapped(point, placed: placed, frame: frame) else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    enqueue(.click(x: mappedPoint.x, y: mappedPoint.y, button: "right", count: 1))
                },
                onMiddleClick: { point in
                    guard let mappedPoint = mapped(point, placed: placed, frame: frame) else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    enqueue(.click(x: mappedPoint.x, y: mappedPoint.y, button: "middle", count: 1))
                },
                onPointerMove: { point in
                    guard let mappedPoint = mapped(point, placed: placed, frame: frame, clampToContent: true) else { return }
                    enqueue(.move(x: mappedPoint.x, y: mappedPoint.y))
                },
                onPointerEnded: {
                    // Vamp flushes the final coalesced sample on drag end.
                    inputSender.flush()
                },
                onScroll: { dx, dy in
                    let scaled = RemoteDisplayMapping.scaleViewDeltaToDisplay(
                        dx: dx,
                        dy: dy,
                        contentWidth: Double(placed.width),
                        contentHeight: Double(placed.height),
                        displayWidth: frame.displayWidth,
                        displayHeight: frame.displayHeight)
                    enqueue(.scroll(x: nil, y: nil, dx: scaled.dx, dy: scaled.dy))
                },
                onViewportPan: { delta in
                    offset = clampedOffset(
                        CGSize(width: offset.width + delta.width, height: offset.height + delta.height),
                        zoom: zoom,
                        in: geo.size
                    )
                },
                onPinchChanged: { scale, focalPoint in
                    let oldZoom = zoom
                    let newZoom = min(max(zoom * scale, 1), 5)
                    zoom = newZoom
                    if newZoom <= 1 {
                        offset = .zero
                    } else {
                        let ratio = newZoom / max(oldZoom, 0.001)
                        let centerX = geo.size.width / 2
                        let centerY = geo.size.height / 2
                        let nextX = offset.width + (1 - ratio) * (focalPoint.x - centerX - offset.width)
                        let nextY = offset.height + (1 - ratio) * (focalPoint.y - centerY - offset.height)
                        offset = clampedOffset(
                            CGSize(width: nextX, height: nextY),
                            zoom: newZoom,
                            in: geo.size
                        )
                    }
                },
                onPinchEnded: {
                    if zoom < 1.15 {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                            zoom = 1
                            offset = .zero
                        }
                    }
                },
                onLongPress: { point in
                    if let mappedPoint = mapped(point, placed: placed, frame: frame, clampToContent: true) {
                        enqueue(.move(x: mappedPoint.x, y: mappedPoint.y))
                    }
                    toggleDragLock()
                },
                onHoverDelta: { dx, dy in
                    let scaled = RemoteDisplayMapping.scaleViewDeltaToDisplay(
                        dx: dx,
                        dy: dy,
                        contentWidth: Double(placed.width),
                        contentHeight: Double(placed.height),
                        displayWidth: frame.displayWidth,
                        displayHeight: frame.displayHeight)
                    let accel = RemoteDisplayMapping.accelerated(dx: scaled.dx, dy: scaled.dy)
                    enqueue(.relative(dx: accel.dx, dy: accel.dy))
                }
            )
            .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func screenPreview(image: UIImage) -> some View {
        GeometryReader { geo in
            let fitted = fittedSize(image.size, in: geo.size)
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(previewZoom)
                .offset(previewOffset)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / lastPreviewPinch
                                lastPreviewPinch = value
                                previewZoom = min(max(previewZoom * delta, 1), 4)
                                previewOffset = clampedPreviewOffset(previewOffset, zoom: previewZoom, in: fitted)
                            }
                            .onEnded { _ in lastPreviewPinch = 1 },
                        DragGesture()
                            .onChanged { gesture in
                                guard previewZoom > 1 else { return }
                                let dx = gesture.translation.width - lastPreviewDrag.width
                                let dy = gesture.translation.height - lastPreviewDrag.height
                                lastPreviewDrag = gesture.translation
                                previewOffset = clampedPreviewOffset(
                                    CGSize(width: previewOffset.width + dx, height: previewOffset.height + dy),
                                    zoom: previewZoom,
                                    in: fitted
                                )
                            }
                            .onEnded { _ in lastPreviewDrag = .zero }
                    )
                )
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("stats")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
            statLine("fps", fpsText)
            statLine("kbps", bitrateText)
            statLine("screen", screenLatencyText)
            statLine("input", latencyText)
            statLine("queue", "\(inputSender.pendingCount)")
            statLine("stream", streamResolution.title)
            statLine("source", selectedApplication?.name ?? "display")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 28)
        .padding(.bottom, 104)
        .allowsHitTesting(false)
    }

    private func statLine(_ key: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(key).foregroundStyle(.white.opacity(0.48))
            Text(value).foregroundStyle(Self.accent).monospacedDigit()
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
    }

    private func classicBottomChrome(bottomInset: CGFloat) -> some View {
        HStack(spacing: 0) {
            classicIconButton(systemName: "xmark", destructive: true) { dismiss() }
            classicIconButton(
                systemName: markup.isVisible ? "pencil.slash" : "pencil.tip",
                active: markup.isVisible
            ) {
                markup.isVisible.toggle()
            }
            classicIconButton(
                systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard",
                active: showKeyboard
            ) {
                showKeyboard.toggle()
            }
            classicIconButton(systemName: "terminal") { showTerminal = true }
            classicIconButton(
                systemName: audioPlayer.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                active: audioPlayer.isActive && !audioPlayer.isMuted
            ) {
                audioPlayer.isMuted.toggle()
            }
            if sourceMode == .display, let displays = status?.displays, displays.count > 1 {
                classicIconButton(systemName: "rectangle.on.rectangle.angled") {
                    cycleDisplay(in: displays)
                }
                Menu {
                    ForEach(displays) { display in
                        Button {
                            selectedWindowID = nil
                            selectedDisplayID = display.id
                        } label: {
                            let sizeLabel: String = {
                                if let w = display.width, let h = display.height {
                                    return "\(display.name) · \(Int(w))×\(Int(h))"
                                }
                                return display.name
                            }()
                            Label(sizeLabel, systemImage: selectedDisplayID == display.id ? "checkmark" : "display")
                        }
                    }
                } label: {
                    classicIconLabel(systemName: "display.2", active: false)
                }
                .buttonStyle(.plain)
            }
            if sourceMode == .application {
                Menu {
                    if applications.isEmpty {
                        Text("No streamable applications")
                    } else {
                        ForEach(applications) { application in
                            Button {
                                selectedWindowID = application.windowID
                            } label: {
                                Label {
                                    Text("\(application.name) · \(application.detail)")
                                } icon: {
                                    Image(systemName: selectedWindowID == application.windowID ? "checkmark" : "macwindow")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        Task { await refreshApplications() }
                    } label: {
                        Label("Refresh applications", systemImage: "arrow.clockwise")
                    }
                } label: {
                    classicIconLabel(systemName: "macwindow.on.rectangle", active: selectedWindowID != nil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose streamed application")
            }
            Menu {
                Menu {
                    ForEach(RemoteStreamResolution.allCases) { resolution in
                        Button {
                            streamResolutionRaw = resolution.rawValue
                            streamRestart.bump()
                        } label: {
                            Label(resolution.title, systemImage: streamResolution == resolution ? "checkmark" : "rectangle.on.rectangle")
                        }
                    }
                } label: {
                    Label("Stream Resolution · \(streamResolution.title)", systemImage: "slider.horizontal.3")
                }
                Button { shareScreenshot() } label: { Label("Screenshot", systemImage: "camera") }
                Button {
                    fillScreen.toggle()
                    resetZoom()
                } label: {
                    Label(fillScreen ? "Fit Display" : "Fill Screen", systemImage: fillScreen ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward")
                }
                Button { pastePhoneClipboard() } label: { Label("Paste from iPhone", systemImage: "doc.on.clipboard") }
                Button { Task { await sendPhoneClipboardToMac() } } label: { Label("Send Clipboard to Mac", systemImage: "arrow.up.doc") }
                Button { Task { await copyMacClipboard() } } label: { Label("Get Clipboard from Mac", systemImage: "arrow.down.doc") }
                Button { enqueue(.key("tab", modifiers: ["cmd"])) } label: { Label("Switch Remote App (⌘Tab)", systemImage: "command") }
                Button { showStats.toggle() } label: { Label(showStats ? "Hide Stats" : "Stats", systemImage: "chart.bar") }
                Divider()
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) { hideChrome = true }
                } label: { Label("Hide Controls", systemImage: "eye.slash") }
            } label: {
                classicIconLabel(systemName: fillScreen ? "rectangle.arrowtriangle.2.outward" : "ellipsis", active: fillScreen)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 22)
                .padding(.horizontal, 2)

            classicIconButton(systemName: "eye.slash", dimmed: true) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) { hideChrome = true }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Self.panel.opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 14, y: 7)
        .padding(.horizontal, 10)
        .padding(.bottom, bottomInset + 8)
    }

    private func classicIconButton(
        systemName: String,
        active: Bool = false,
        dimmed: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            classicIconLabel(systemName: systemName, active: active, dimmed: dimmed, destructive: destructive)
        }
        .buttonStyle(.plain)
    }

    private func classicIconLabel(
        systemName: String,
        active: Bool,
        dimmed: Bool = false,
        destructive: Bool = false
    ) -> some View {
        ZStack {
            if destructive {
                Circle().fill(Color(white: 0.34).opacity(0.95)).frame(width: 30, height: 30)
            }
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    destructive ? .white : active ? Self.accent : dimmed ? .white.opacity(0.38) : .white.opacity(0.82)
                )
        }
        .frame(width: 38, height: 38)
        .contentShape(Circle())
    }

    private func revealButton(bottomInset: CGFloat) -> some View {
        HStack {
            Spacer()
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) { hideChrome = false }
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.22), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, bottomInset + 14)
    }

    private func startAudio() {
        audioTask?.cancel()
        audioPlayer.start()
        audioTask = Task { @MainActor in
            var attempt = 0
            while !Task.isCancelled {
                do {
                    for try await chunk in store.controlAudio() {
                        guard !Task.isCancelled else { return }
                        attempt = 0
                        audioPlayer.receive(chunk)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    attempt += 1
                    if attempt == 1 { errorText = "Mac audio reconnecting…" }
                    let delay = min(pow(2.0, Double(attempt - 1)), 8.0)
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func configureDecoder() {
        let binder = videoBinder
        let diag = diagnostics
        decoder.setOutputHandler { pixelBuffer in
            Task { @MainActor in
                binder.enqueue(pixelBuffer)
                diag.noteDecodeOK()
            }
        }
        decoder.setEventHandler { message in
            Task { @MainActor in
                if message.hasPrefix("need keyframe") || message.contains("failed") || message.contains("status=") {
                    diag.noteDecodeError(message)
                } else {
                    diag.breadcrumb(message)
                }
            }
        }
    }

    private func run() async {
        diagnostics.resetSession()
        diagnostics.setPhase("status")
        while !Task.isCancelled {
            let generation = streamGeneration
            do {
                diagnostics.breadcrumb("fetch /api/control")
                status = try await store.macControlStatus()
                guard status?.ready == true else {
                    reconnectBanner = "Waiting for Mac Control…"
                    diagnostics.setPhase("mac control off")
                    diagnostics.breadcrumb(status?.message ?? "not ready")
                    try? await Task.sleep(for: .milliseconds(750))
                    continue
                }
                if sourceMode == .application {
                    await refreshApplications()
                    if selectedWindowID == nil {
                        selectedWindowID = applications.first?.windowID
                    }
                    guard selectedWindowID != nil else {
                        reconnectBanner = "Open an application on your Mac to stream it."
                        diagnostics.setPhase("waiting for application")
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                } else if selectedDisplayID == nil {
                    selectedWindowID = nil
                    selectedDisplayID = status?.displays?.first?.id
                }
                reconnectBanner = nil
                reconnectAttempt = 0
                errorText = nil
                diagnostics.setPhase("opening stream")
                diagnostics.breadcrumb(
                    "stream display=\(activeDisplayID.map(String.init) ?? "auto") window=\(activeWindowID.map(String.init) ?? "none") res=\(streamResolution.rawValue)"
                )
                for try await next in store.macControlFrames(
                    displayID: activeDisplayID,
                    windowID: activeWindowID,
                    resolution: streamResolution
                ) {
                    try Task.checkCancellation()
                    guard generation == streamGeneration else {
                        diagnostics.breadcrumb("generation bump — restart stream")
                        break
                    }
                    let now = Date()
                    if let lastFrameAt {
                        let dt = max(now.timeIntervalSince(lastFrameAt), 0.001)
                        fpsText = String(format: "%.0f", min(1 / dt, 99))
                        let bits = Double(next.byteCount) * 8.0 / dt
                        bitrateText = String(format: "%.0f", bits / 1000.0)
                    }
                    if let lastFrameAt, now.timeIntervalSince(lastFrameAt) > 3 {
                        reconnectBanner = "Stream stalled…"
                    } else {
                        reconnectBanner = nil
                    }
                    lastFrameAt = now
                    lastFrameBytes = next.byteCount
                    screenLatencyText = "live"
                    latencyText = inputSender.lastRoundTripMilliseconds.map { "\($0) ms" } ?? "—"
                    frame = next
                    errorText = nil
                    if case .h264(let data, let keyframe, let parameterSets) = next.payload {
                        diagnostics.noteFrame(
                            bytes: data.count,
                            keyframe: keyframe,
                            hasParams: parameterSets?.isEmpty == false,
                            size: "\(next.imageWidth)x\(next.imageHeight)")
                        decoder.decode(data: data, keyframe: keyframe, parameterSets: parameterSets)
                    }
                }
                if generation == streamGeneration {
                    diagnostics.breadcrumb("stream ended")
                    diagnostics.setPhase("stream ended")
                }
            } catch is CancellationError {
                return
            } catch {
                reconnectAttempt += 1
                reconnectBanner = "Reconnecting… attempt \(reconnectAttempt)"
                // Stream/parse details stay in Settings → Control Diagnostics only.
                diagnostics.noteError(error.localizedDescription)
                diagnostics.setPhase("reconnect")
                do {
                    let started = ProcessInfo.processInfo.systemUptime
                    let still = try await store.macControlFrame(
                        displayID: activeDisplayID,
                        windowID: activeWindowID,
                        resolution: streamResolution)
                    screenLatencyText = "\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms"
                    latencyText = inputSender.lastRoundTripMilliseconds.map { "\($0) ms" } ?? "—"
                    if let lastFrameAt {
                        fpsText = String(format: "%.0f", min(1 / max(Date().timeIntervalSince(lastFrameAt), 0.001), 99))
                    }
                    lastFrameAt = Date()
                    frame = still
                    diagnostics.breadcrumb("still JPEG ok \(still.imageWidth)x\(still.imageHeight)")
                } catch {
                    diagnostics.noteError("still: \(error.localizedDescription)")
                }
                let delayMs = min(Int(pow(2.0, Double(min(reconnectAttempt, 4)))) * 250, 4_000)
                try? await Task.sleep(for: .milliseconds(max(delayMs, streamResolution.refreshIntervalMilliseconds)))
            }
        }
    }

    @MainActor
    private func refreshApplications() async {
        do {
            let next = try await store.macControlApplications()
            applications = next
            if let selectedWindowID,
               !next.contains(where: { $0.windowID == selectedWindowID }) {
                self.selectedWindowID = next.first?.windowID
                reconnectBanner = next.isEmpty
                    ? "Open an application on your Mac to stream it."
                    : "The selected app closed. Switched to another app."
                diagnostics.breadcrumb("selected window disappeared — app stream refreshed")
            }
        } catch is CancellationError {
            return
        } catch {
            diagnostics.noteError("apps: \(error.localizedDescription)")
        }
    }

    private func enqueue(_ command: RemoteInputSender.Command) {
        inputSender.enqueue(command)
    }

    private func toggleDragLock() {
        dragLocked.toggle()
        if dragLocked {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        } else {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        enqueue(dragLocked ? .down(button: "left") : .up(button: "left"))
    }

    private func cycleDisplay(in displays: [RemoteMacDisplay]) {
        guard !displays.isEmpty else { return }
        selectedWindowID = nil
        let current = selectedDisplayID ?? displays[0].id
        let index = displays.firstIndex(where: { $0.id == current }) ?? 0
        let next = displays[(index + 1) % displays.count]
        selectedDisplayID = next.id
        streamRestart.bump()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func pastePhoneClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        enqueue(.type(text))
    }

    private func sendPhoneClipboardToMac() async {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if await store.sendClipboardToMac(text) { errorText = nil }
    }

    private func copyMacClipboard() async {
        if let text = await store.copyMacClipboard() {
            UIPasteboard.general.string = text
            errorText = nil
        }
    }

    private func shareScreenshot() {
        Task { @MainActor in
            do {
                let still = try await store.macControlFrame(
                    displayID: activeDisplayID,
                    windowID: activeWindowID,
                    resolution: streamResolution)
                guard let jpeg = still.jpegStill, let image = UIImage(data: jpeg) else {
                    screenshotStatus = "No frame to capture"
                    return
                }
                shareItems = [image]
                showShare = true
            } catch {
                screenshotStatus = error.localizedDescription
                errorText = error.localizedDescription
            }
        }
    }

    private func fittedSize(_ image: CGSize, in bounds: CGSize) -> CGSize {
        RemoteDisplayMapping.contentRect(imageSize: image, in: bounds, mode: .fit).size
    }

    private func mapped(
        _ location: CGPoint,
        placed: CGRect,
        frame: RemoteMacControlFrame,
        clampToContent: Bool = false
    ) -> CGPoint? {
        RemoteDisplayMapping.mapPoint(
            location,
            contentRect: placed,
            displayX: frame.displayX,
            displayY: frame.displayY,
            displayWidth: frame.displayWidth,
            displayHeight: frame.displayHeight,
            clampToContent: clampToContent)
    }

    private func clampedOffset(_ proposed: CGSize, zoom: CGFloat, in viewSize: CGSize) -> CGSize {
        guard zoom > 1 else { return .zero }
        let maxX = viewSize.width * (zoom - 1) / 2
        let maxY = viewSize.height * (zoom - 1) / 2
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func clampedPreviewOffset(_ proposed: CGSize, zoom: CGFloat, in size: CGSize) -> CGSize {
        guard zoom > 1 else { return .zero }
        let maxX = size.width * (zoom - 1) / 2
        let maxY = size.height * (zoom - 1) / 2
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func resetZoom() {
        zoom = 1
        offset = .zero
        previewZoom = 1
        previewOffset = .zero
        lastPreviewPinch = 1
        lastPreviewDrag = .zero
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
final class RemoteStreamRestart: ObservableObject {
    @Published private(set) var generation = 0

    func bump() {
        generation &+= 1
    }
}

@MainActor
final class RemoteMarkupStore: ObservableObject {
    enum Tool: String, CaseIterable { case draw, highlight, erase }

    struct Stroke: Identifiable {
        let id = UUID()
        var tool: Tool
        var points: [CGPoint]
    }

    @Published var tool: Tool = .draw
    @Published var strokes: [Stroke] = []
    @Published var isVisible = false

    func begin(at point: CGPoint) {
        if tool == .erase { erase(near: point); return }
        strokes.append(Stroke(tool: tool, points: [point]))
    }

    func append(_ point: CGPoint) {
        guard tool != .erase, !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(point)
    }

    func clear() { strokes.removeAll() }

    private func erase(near point: CGPoint) {
        strokes.removeAll { stroke in
            stroke.points.contains { hypot($0.x - point.x, $0.y - point.y) < 28 }
        }
    }
}

private struct RemoteMarkupOverlay: View {
    @ObservedObject var store: RemoteMarkupStore

    var body: some View {
        Canvas { context, _ in
            for stroke in store.strokes {
                guard let first = stroke.points.first else { continue }
                var path = Path()
                path.move(to: first)
                for point in stroke.points.dropFirst() { path.addLine(to: point) }
                let color: Color = stroke.tool == .highlight ? .yellow.opacity(0.35) : .yellow
                let width: CGFloat = stroke.tool == .highlight ? 12 : 3
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if value.translation == .zero { store.begin(at: value.location) }
                    else { store.append(value.location) }
                }
        )
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                ForEach(RemoteMarkupStore.Tool.allCases, id: \.self) { tool in
                    Button { store.tool = tool } label: {
                        Image(systemName: tool == .draw ? "pencil.tip" : tool == .highlight ? "highlighter" : "eraser")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(store.tool == tool ? Color(white: 0.46) : Color.black.opacity(0.55), in: Circle())
                    }
                }
                Button("Clear") { store.clear() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .padding(12)
        }
    }
}
