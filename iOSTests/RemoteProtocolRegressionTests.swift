import Foundation
import os
import XCTest
import SwiftUI
import UIKit
@testable import BeetCodeRemoteIOS

final class RemoteProtocolRegressionTests: XCTestCase {
    func testUnauthorizedResponseRequiresPairingAndPreservesServerMessage() {
        let body = Data(#"{"error":"The saved access token expired."}"#.utf8)
        let error = RemoteAPIClient.responseError(statusCode: 401, data: body)

        XCTAssertTrue(error.requiresPairing)
        XCTAssertEqual(error.errorDescription, "The saved access token expired.")
    }

    func testNonAuthenticationResponseDoesNotRequestPairing() {
        let error = RemoteAPIClient.responseError(statusCode: 423, fallback: "The Mac is locked.")

        XCTAssertFalse(error.requiresPairing)
        XCTAssertEqual(error.errorDescription, "The Mac is locked.")
    }

    func testRevisionOrderingRejectsOnlyAnOlderVersionedSnapshot() {
        XCTAssertFalse(RemoteStore.shouldAcceptSessionRevision(current: 42, incoming: 41))
        XCTAssertTrue(RemoteStore.shouldAcceptSessionRevision(current: 42, incoming: 42))
        XCTAssertTrue(RemoteStore.shouldAcceptSessionRevision(current: 42, incoming: 43))
        XCTAssertTrue(RemoteStore.shouldAcceptSessionRevision(current: 42, incoming: nil))
        XCTAssertTrue(RemoteStore.shouldAcceptSessionRevision(current: nil, incoming: 1))
    }

    func testServerMessageIdentitySurvivesSnapshotContentChanges() throws {
        let first = try decodeMessage(id: "session:message:17", content: "Working", timestamp: 10)
        let updated = try decodeMessage(id: "session:message:17", content: "Finished", timestamp: 11)

        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(updated.id, "session:message:17")
    }

    func testLegacySavedComputerDecodesWithoutNewMetadata() throws {
        let id = UUID()
        let data = Data(#"{"id":"\#(id.uuidString)","name":"Studio Mac","baseURL":"http:\/\/192.168.1.10:9575"}"#.utf8)
        let computer = try JSONDecoder().decode(PairedBeetCodeComputer.self, from: data)

        XCTAssertEqual(computer.id, id)
        XCTAssertNil(computer.tokenExpiresAt)
        XCTAssertNil(computer.networkKind)
    }

    func testStatusDecodesTokenExpiryAndTransportKind() throws {
        let data = Data(#"{"pairedClients":1,"networkKind":"localNetwork","tokenExpiresAt":1798761600,"isRunning":false,"phase":"idle","queuedTasks":0}"#.utf8)
        let status = try JSONDecoder().decode(RemoteStatus.self, from: data)

        XCTAssertEqual(status.networkKind, "localNetwork")
        XCTAssertEqual(status.tokenExpiresAt, 1_798_761_600)
    }

    func testMacControlStatusDecodesRemoteUnlockCapability() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true,"remoteUnlockEnabled":true,"remoteUnlockAvailable":true,"remoteUnlockMessage":"Enter the Mac login password.","displays":[]}"#.utf8)
        let status = try JSONDecoder().decode(RemoteMacControlStatus.self, from: data)

        XCTAssertTrue(status.locked == true)
        XCTAssertTrue(status.remoteUnlockEnabled == true)
        XCTAssertTrue(status.remoteUnlockAvailable == true)
        XCTAssertEqual(status.remoteUnlockMessage, "Enter the Mac login password.")
        XCTAssertTrue(status.shouldOfferRemoteUnlock)
    }

    func testLegacyMacControlStatusLeavesRemoteUnlockUnavailable() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true}"#.utf8)
        let status = try JSONDecoder().decode(RemoteMacControlStatus.self, from: data)

        XCTAssertNil(status.remoteUnlockEnabled)
        XCTAssertNil(status.remoteUnlockAvailable)
        XCTAssertNil(status.remoteUnlockMessage)
        XCTAssertFalse(status.shouldOfferRemoteUnlock)
    }

    func testLockedStatusDoesNotOfferPasswordFieldOnUnencryptedPath() throws {
        let data = Data(#"{"enabled":true,"screenRecording":true,"accessibility":true,"ready":false,"locked":true,"remoteUnlockEnabled":true,"remoteUnlockAvailable":false,"remoteUnlockMessage":"Remote Unlock requires the encrypted Tailscale connection."}"#.utf8)
        let status = try JSONDecoder().decode(RemoteMacControlStatus.self, from: data)

        XCTAssertFalse(status.shouldOfferRemoteUnlock)
    }

    func testKeyboardTransitionCannotReplaceStableStreamViewport() {
        let size = CGSize(width: 393, height: 852)

        XCTAssertTrue(RemoteViewportStability.shouldAccept(
            size,
            keyboardOverlayVisible: false,
            keyboardInset: 0))
        XCTAssertFalse(RemoteViewportStability.shouldAccept(
            size,
            keyboardOverlayVisible: true,
            keyboardInset: 0), "the overlay flag must close the notification-ordering race")
        XCTAssertFalse(RemoteViewportStability.shouldAccept(
            size,
            keyboardOverlayVisible: false,
            keyboardInset: 320))
    }

    func testHoverDeltaUsesVampDirectRelativePath() {
        let delta = RemoteDisplayMapping.hoverDelta(dx: 10, dy: -6)

        XCTAssertEqual(delta.dx, 12.33238075793812, accuracy: 0.000001)
        XCTAssertEqual(delta.dy, -7.399428454762871, accuracy: 0.000001)
    }

    @MainActor
    func testSlowHoverRequestCoalescesLatestMotion() async {
        let firstRequestStarted = expectation(description: "first input request started")
        let allRequestsFinished = expectation(description: "coalesced input delivered")
        let gate = InputRequestGate()
        var received: [RemoteInputCommand] = []

        let sender = RemoteInputSender(sendCommands: { commands in
            if commands.first == .relative(dx: 1, dy: 0), gate.claimFirstRequest() {
                firstRequestStarted.fulfill()
                await gate.wait()
            }
            received.append(contentsOf: commands)
            if received.last == .relative(dx: 5, dy: 0) {
                allRequestsFinished.fulfill()
            }
        })

        sender.enqueue(.relative(dx: 1, dy: 0))
        await fulfillment(of: [firstRequestStarted], timeout: 2)
        sender.enqueue(.relative(dx: 2, dy: 0))
        sender.flush()
        sender.enqueue(.relative(dx: 3, dy: 0))
        sender.flush()
        await gate.release()
        await fulfillment(of: [allRequestsFinished], timeout: 2)

        XCTAssertEqual(received, [.relative(dx: 1, dy: 0), .relative(dx: 5, dy: 0)])
        XCTAssertEqual(sender.sentCount, 2)
        XCTAssertEqual(sender.pendingCount, 0)
        XCTAssertNil(sender.lastError)
        sender.stop()
    }

    private func decodeMessage(id: String, content: String, timestamp: Double) throws -> RemoteMessage {
        let object: [String: Any] = [
            "id": id,
            "role": "assistant",
            "content": content,
            "timestamp": timestamp,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(RemoteMessage.self, from: data)
    }
}

/// Lets one asynchronous test request stay in flight while newer samples arrive.
private final class InputRequestGate: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (isFirstRequestClaimed: false, continuation: nil as CheckedContinuation<Void, Never>?)
    )

    func claimFirstRequest() -> Bool {
        state.withLock { values in
            guard !values.isFirstRequestClaimed else { return false }
            values.isFirstRequestClaimed = true
            return true
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            state.withLock { values in
                values.continuation = continuation
            }
        }
    }

    func release() async {
        let continuation = state.withLock { values -> CheckedContinuation<Void, Never>? in
            let continuation = values.continuation
            values.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

/// Renders production surfaces with isolated in-memory data, never saved credentials.
/// Images are XCTest attachments; this is not a second application or a preview route.
final class RemoteInstrumentRenderingTests: XCTestCase {
    @MainActor func testConfigurationPanels() async throws {
        RemoteStubProtocol.handler.withLock { $0 = { request in
            let payload: String
            switch request.url!.path {
            case "/api/status": payload = #"{"pairedClients":1,"networkKind":"tailscale","isRunning":false,"phase":"idle","queuedTasks":0}"#
            case "/api/sessions": payload = #"{"sessions":[]}"#
            case "/api/models": payload = #"{"models":[{"id":"qwen","name":"Qwen3.5 9B MLX 4bit","source":"local","detail":"On your Mac"}]}"#
            case "/api/workspaces": payload = #"{"workspaces":[]}"#
            case "/api/bot-computers": payload = #"{"computers":[]}"#
            case "/api/bot-runs": payload = #"{"runs":[]}"#
            default: return (404, Data(#"{"error":"Unknown endpoint"}"#.utf8))
            }
            return (200, Data(payload.utf8))
        } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteStubProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = RemoteStore(connectionStorage: MemoryConnectionStorage([
            PairedBeetCodeComputer(name: "Studio Mac", baseURL: URL(string: "http://192.168.1.1:9575")!)
        ]), apiSession: session, observesNotifications: false, drafts: RemoteDraftStore(directory: nil))
        defer { store.forgetSavedMac(); session.invalidateAndCancel() }
        try await store.refresh()
        XCTAssertTrue(store.isConnected)
        await store.loadStartModels()
        XCTAssertEqual(store.startModels.count, 1)
        let phone = CGSize(width: 402, height: 874)
        let ipad = CGSize(width: 834, height: 1194)
        let empty = StartSessionSheet(store: store, initialBotID: "", onStarted: { _ in })
        let populated = StartSessionSheet(store: store, initialBotID: "",
            initialPrompt: "Plan a focused release review. Check the changes, explain the risks, and list the next steps.", onStarted: { _ in })
        let settings = RemoteSettingsSheet(store: store, onSwitchComputer: {}, onDiagnostics: {})
        try await capture(empty, name: "panel-new-session", size: phone)
        try await capture(populated, name: "panel-task-ready", size: phone)
        try await capture(populated, name: "panel-task-accessibility", size: phone, accessibility: true)
        try await capture(populated, name: "panel-task-ipad", size: ipad)
        try await capture(populated, name: "panel-task-landscape", size: CGSize(width: 874, height: 402), compactHeight: true)
        try await capture(settings, name: "panel-settings-connected", size: phone)
        try await capture(settings, name: "panel-settings-accessibility", size: phone, accessibility: true)
        try await capture(settings, name: "panel-settings-ipad", size: ipad)
        store.forgetSavedMac()
        XCTAssertFalse(store.isConnected)
        try await capture(settings, name: "panel-settings-disconnected", size: phone)
    }

    @MainActor func testComposerIntrinsicSizing() {
        for width in [320.0, 402.0, 740.0] {
            func height(_ text: String, compact: Bool = false) -> CGFloat {
                let view = RemoteComposer(draft: .constant(text), isRunning: false, onSend: {}, onStop: {})
                    .environment(\.dynamicTypeSize, .large)
                    .environment(\.verticalSizeClass, compact ? .compact : .regular)
                let host = UIHostingController(rootView: view)
                return host.sizeThatFits(in: CGSize(width: width, height: 1000)).height
            }
            let empty = height("")
            XCTAssertLessThanOrEqual(empty, 100, "Empty composer must remain compact at width \(width)")
            XCTAssertGreaterThanOrEqual(empty, 90)
            XCTAssertEqual(height("A short draft"), empty, accuracy: 2)
            let six = height("One\nTwo\nThree\nFour\nFive\nSix")
            XCTAssertGreaterThan(six, empty + 60)
            XCTAssertEqual(height("One\nTwo\nThree\nFour\nFive\nSix\nSeven\nEight"), six, accuracy: 2)
            XCTAssertLessThan(height("One\nTwo\nThree\nFour", compact: true), six)
        }
    }

    @MainActor func testAdvancedAccessBankFitsNarrowLayouts() {
        for (width, typeSize, minimumHeight) in [
            (288.0, DynamicTypeSize.large, 50.0),
            (288.0, DynamicTypeSize.accessibility3, 117.0),
        ] {
            let bank = RemoteAdvancedAccessBank(
                autoMode: .constant(true),
                fullAccess: .constant(false)
            )
            .environment(\.dynamicTypeSize, typeSize)
            let host = UIHostingController(rootView: bank)
            let fitted = host.sizeThatFits(in: CGSize(width: width, height: 400))
            XCTAssertLessThanOrEqual(fitted.width, width + 0.5)
            XCTAssertGreaterThanOrEqual(fitted.height, minimumHeight)
        }
    }

    @MainActor func testCompactDesignStates() async throws {
        try await capture(RemoteKeyStatePreview(), name: "keycap-states", size: CGSize(width: 402, height: 600))
        try await capture(RemoteKeyStatePreview(), name: "keycap-contrast-states", size: CGSize(width: 402, height: 600), increasedContrast: true)
        try await capture(RemoteComposerFixture(), name: "composer-design", size: CGSize(width: 402, height: 874))
        try await capture(RemoteComposerFixture(), name: "composer-small", size: CGSize(width: 320, height: 700), narrow: true)
        try await capture(RemoteComposerFixture(), name: "composer-split", size: CGSize(width: 375, height: 900), narrow: true)
        try await capture(RemoteComposerFixture(), name: "composer-accessibility", size: CGSize(width: 402, height: 874), accessibility: true)
    }

    @MainActor func testConnectionLostAtShortHeight() async throws {
        try await capture(RemoteControlUnavailableState(title: "Mac unavailable",
            message: "The connection was interrupted. Your existing session stays on your Mac. Reconnect when your Mac is available.",
            status: "CONNECTION LOST", symbol: "wifi.slash", isWorking: false, topInset: 0, bottomInset: 0,
            primaryTitle: "Reconnect", primaryAction: {}, dismiss: {}),
            name: "27-connection-lost-landscape-accessibility", size: CGSize(width: 874, height: 402),
            accessibility: true, compactHeight: true)
    }

    @MainActor func testProductionSurfaceMatrix() async throws {
        let store = RemoteStore(connectionStorage: MemoryConnectionStorage([]), observesNotifications: false,
                                drafts: RemoteDraftStore(directory: nil))
        let detail = try JSONDecoder().decode(RemoteSessionDetail.self, from: Data(#"{"id":"11111111-1111-1111-1111-111111111111","title":"A quieter workspace","workspace":"Chat","modelID":"GPT-5 Codex","isRunning":false,"phase":"idle","streamingText":"","messages":[{"id":"1","role":"user","content":"Help me plan a calmer workspace.","timestamp":1},{"id":"2","role":"assistant","content":"Start with the things you use every day.\n\n**1. Clear the desk**\nKeep your display, keyboard, and one notebook within reach.\n\n**2. Give everything a place**\nUse a small tray for cables and a shelf for everything else.","timestamp":2}]}"#.utf8))
        store.selectedSession = detail
        store.sessions = [RemoteSessionSummary(id: detail.id, title: detail.title, workspace: "Personal", workspacePath: nil,
            mode: "chat", messageCount: 8, updatedAt: Date().timeIntervalSince1970 - 120, isRunning: false, phase: "idle", queueState: nil)]
        store.startModels = [RemoteStartModelOption(id: "codex", name: "GPT-5 Codex", source: "local",
            detail: "On your Mac", reasoningEfforts: nil, defaultReasoningEffort: nil)]
        let chat = NavigationStack { ConversationView(store: store, sessionID: detail.id) }
        let settings = RemoteSettingsSheet(store: store, onSwitchComputer: {}, onDiagnostics: {})
        let models = RemoteModelPickerSheet(models: store.startModels, source: .constant("local"), selectedModelID: .constant("codex"))
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        let size = tablet ? CGSize(width: 834, height: 1194) : CGSize(width: 402, height: 874)
        try await capture(chat, name: "01-chat", size: size)
        try await capture(chat, name: "02-chat-keyboard", size: size, focusEditor: true)
        store[draftFor: detail.id] = "Review the iOS layout.\nCheck portrait and landscape.\nPreserve every existing action.\nSummarize the changes.\nCheck long prompts as well.\nKeep Send reachable."
        try await capture(chat, name: "03-chat-multiline", size: size)
        store[draftFor: detail.id] = ""
        try await capture(chat, name: "04-chat-accessibility", size: size, accessibility: true)
        try await capture(SessionNavigationView(store: store), name: "05-sessions", size: size)
        try await capture(StartSessionSheet(store: store, initialBotID: "", onStarted: { _ in }), name: "06-new-session", size: size)
        try await capture(RemoteBotsView(store: store, onOpen: { _ in }), name: "07-bots", size: size)
        try await capture(NavigationStack {
            RemoteBotDetailView(store: store, profile: RemoteBotProfile.profile(id: "builder"), selectedModelID: .constant("codex"), onOpen: { _ in })
        }, name: "08-bot-detail-chat", size: size)
        try await capture(NavigationStack {
            RemoteBotDetailView(store: store, profile: RemoteBotProfile.profile(id: "builder"), selectedModelID: .constant("codex"), initialMode: "run", onOpen: { _ in })
        }, name: "09-bot-detail-run", size: size)
        try await capture(models, name: "10-models", size: size)
        try await capture(RemoteComposerToolsSheet(onChoose: { _ in }), name: "11-tools", size: size)
        let pending = try JSONDecoder().decode(RemotePendingInteraction.self, from: Data(#"{"kind":"approval","toolName":"edit_file","summary":"Update the screen title","preview":{"kind":"diff","path":"Views/Chat.swift","content":"- Text(\"Chat\")\n+ Text(\"Conversation\")","added":1,"removed":1}}"#.utf8))
        try await capture(VStack { Spacer(); PendingInteractionView(pending: pending, onResolve: { _ in }) }
            .background(RemoteInstrument.canvas), name: "12-approval", size: size)
        try await capture(PairingView(store: store), name: "13-pairing", size: size)
        try await capture(RemoteControlUnavailableState(title: "Mac unavailable", message: "Tap to retry the connection to your Mac.",
            status: "CONNECTION LOST", symbol: "wifi.slash", isWorking: false, topInset: 0, bottomInset: 0,
            primaryTitle: "Reconnect", primaryAction: {}, dismiss: {}), name: "14-connection-lost", size: size)
        try await capture(RemoteShareSheet(store: store), name: "15-sharing", size: size)
        try await capture(settings, name: "16-settings", size: size)
        try await capture(settings, name: "17-settings-accessibility", size: size, accessibility: true)
        try await capture(ScrollView {
            RemoteNoticeLabel(title: "The selected Mac is temporarily unavailable",
                detail: "Your draft is saved. Reconnect to the same Mac to continue this conversation and review any pending approvals.",
                actionTitle: "Retry connection")
                .padding(16)
        }.background(RemoteInstrument.canvas), name: "25-long-warning-accessibility", size: size, accessibility: true)
        try await capture(VStack {
            RemoteApprovalSummary(text: String(repeating: "Review this requested change before allowing it. Your Mac will only apply the operation after your explicit approval. ", count: 12))
            Button("Allow once") {}.buttonStyle(RemotePrimaryButtonStyle())
            Button("Decline", role: .destructive) {}
        }.padding(16).background(RemoteInstrument.canvas), name: "26-long-approval-accessibility", size: size, accessibility: true)
        try await capture(chat, name: "20-chat-landscape", size: CGSize(width: size.height, height: size.width), compactHeight: !tablet)
        if tablet {
            try await capture(SessionNavigationView(store: store), name: "18-sessions-split", size: CGSize(width: 1194, height: 834))
            try await capture(RemoteBotsView(store: store, onOpen: { _ in }), name: "21-bots-split", size: CGSize(width: 1194, height: 834))
            try await capture(chat, name: "24-reduced-width", size: CGSize(width: 430, height: 1194), narrow: true)
        }
    }

    @MainActor private func capture<V: View>(_ view: V, name: String, size: CGSize,
        accessibility: Bool = false, focusEditor: Bool = false, compactHeight: Bool = false, narrow: Bool = false,
        increasedContrast: Bool = false) async throws {
        let savedAppearance = UserDefaults.standard.object(forKey: "remoteAppearanceSetting")
        defer { UserDefaults.standard.set(savedAppearance, forKey: "remoteAppearanceSetting") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        defer { previousKeyWindow?.makeKeyAndVisible() }
        for scheme in [ColorScheme.light, .dark] {
            UserDefaults.standard.set(scheme == .dark ? "dark" : "light", forKey: "remoteAppearanceSetting")
            let window = UIWindow(windowScene: scene)
            window.frame = focusEditor ? scene.coordinateSpace.bounds : CGRect(origin: .zero, size: size)
            let controller = UIHostingController(rootView: view
                .foregroundStyle(RemoteInstrument.ink).tint(RemoteInstrument.orange)
                .environment(\.remoteAppearance, scheme == .dark ? .dark : .light)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, accessibility ? .accessibility2 : .large)
                .environment(\.horizontalSizeClass, !narrow && size.width >= 700 ? .regular : .compact)
                .environment(\.verticalSizeClass, compactHeight ? .compact : .regular))
            controller.traitOverrides.accessibilityContrast = increasedContrast ? .high : .normal
            controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(400))
            if focusEditor {
                func editor(in view: UIView) -> UIView? {
                    if view is UITextField || view is UITextView { return view }
                    return view.subviews.lazy.compactMap { editor(in: $0) }.first
                }
                XCTAssertTrue(try XCTUnwrap(editor(in: controller.view)).becomeFirstResponder())
                try await Task.sleep(for: .milliseconds(500))
            }
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-\(name)-\(scheme == .dark ? "dark" : "light")-fixture"
            attachment.lifetime = .keepAlways
            add(attachment)
            controller.view.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
