import AppKit
import SwiftUI
import WebKit

/// Docked panel hosting the agent-controlled browser. Mac Chat/Code share one
/// WebView; a specialist bot session hosts that bot's isolated WebView instead.
struct BrowserPanelView: View {
    var onClose: (() -> Void)? = nil
    var controller: BrowserController? = nil

    @EnvironmentObject private var appState: AppState

    var body: some View {
        BrowserPanelChrome(
            onClose: onClose,
            controller: controller ?? BrowserController.shared,
            computers: appState.botComputers.computers)
    }
}

private struct BrowserPanelChrome: View {
    @Environment(\.workspaceWindowID) private var workspaceWindowID
    var onClose: (() -> Void)?

    @ObservedObject var controller: BrowserController
    let computers: [BotComputerRecord]
    @State private var paneWidth: CGFloat = 320
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { controller.back() } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                        .disabled(!controller.webView.canGoBack).accessibilityLabel("Back")
                    Button { controller.forward() } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                        .disabled(!controller.webView.canGoForward).accessibilityLabel("Forward")
                    Button { if controller.isLoading { controller.stop() } else { controller.reload() } } label: {
                        Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise").frame(width: 24, height: 24)
                    }.accessibilityLabel(controller.isLoading ? "Stop loading" : "Reload page")
                    Menu {
                        Button("Vamp Assistant") { NotificationCenter.default.postWorkspace(name: .openWorkspacePanel, object: WorkspacePanel.browser, windowID: workspaceWindowID) }
                        ForEach(computers) { computer in
                            Button(computer.name) {
                                NotificationCenter.default.postWorkspace(name: .openWorkspacePanel,
                                    object: WorkspacePanel.specialistBrowser(computer.id), windowID: workspaceWindowID)
                            }
                        }
                    } label: { Text(controller.ownerLabel.isEmpty ? "Assistant" : controller.ownerLabel).lineLimit(1) }
                    .menuStyle(.borderlessButton).frame(maxWidth: 150)
                    Spacer(minLength: 4)
                    Button {
                        if let url = controller.currentURL ?? controller.webView.url { NSWorkspace.shared.open(url) }
                    } label: { Image(systemName: "safari").frame(width: 24, height: 24) }
                    .disabled((controller.currentURL ?? controller.webView.url) == nil)
                    .accessibilityLabel("Open in Safari")
                    if let onClose { PanelCloseButton(action: onClose) }
                }.buttonStyle(.borderless)
                TextField("Enter a URL…", text: $controller.navigationDraft)
                    .accessibilityIdentifier("browser-url")
                    .vampField().font(.system(size: 13)).autocorrectionDisabled().focused($urlFocused)
                    .onSubmit {
                        let target = controller.navigationDraft.trimmingCharacters(in: .whitespaces)
                        guard !target.isEmpty else { return }
                        do { _ = try controller.open(target); urlFocused = false }
                        catch { controller.lastError = error.localizedDescription }
                    }
            }.padding(12).background(Theme.surface)

            Divider()

            BrowserWebViewHost(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                if let error = controller.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                    Button {
                        controller.lastError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss error")
                    .accessibilityLabel("Dismiss browser error")
                } else if controller.isLoading {
                    ProgressView().controlSize(.mini)
                    Text("Loading \(controller.currentURL?.host ?? "")…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else if let action = controller.lastAgentAction {
                    Image(systemName: "hand.tap")
                        .foregroundStyle(Theme.textSecondary)
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(controller.title.isEmpty
                         ? (controller.currentURL?.absoluteString ?? "No page loaded")
                         : controller.title)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(statusCaption)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Theme.surface)
        .onAppear { if controller.navigationDraft.isEmpty { syncURLDraft() } }
        .onChange(of: controller.currentURL) { _, newValue in
            if !urlFocused, let newValue {
                controller.navigationDraft = newValue.absoluteString
            }
        }
        .onChange(of: controller.ownerLabel) { _, _ in
            syncURLDraft()
        }
    }

    private var statusCaption: String {
        if controller.lastAgentAction != nil { return "Agent is controlling this page" }
        if !controller.ownerLabel.isEmpty { return "\(controller.ownerLabel)'s browser" }
        return "Ready"
    }

    private func syncURLDraft() {
        if let current = controller.currentURL {
            controller.navigationDraft = current.absoluteString
        } else {
            controller.navigationDraft = ""
        }
    }
}

/// Hosts the active WKWebView inside SwiftUI. The web view instance is owned
/// by BrowserController; this representable wraps it in a container view.
/// (Returning the web view itself from makeNSView made updateNSView yank it
/// OUT of SwiftUI's hierarchy into an offscreen container — a blank panel.)
private struct BrowserWebViewHost: NSViewRepresentable {
    var controller: BrowserController

    func makeNSView(context: Context) -> NSView {
        let container = context.coordinator.container
        context.coordinator.controller = controller
        attach(controller.webView, to: container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.controller = controller
        attach(controller.webView, to: nsView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func attach(_ webView: WKWebView, to container: NSView, coordinator: Coordinator) {
        webView.uiDelegate = coordinator
        for subview in container.subviews where subview !== webView {
            subview.removeFromSuperview()
        }
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        // Always re-assert the frame: SwiftUI can move the web view between
        // hosts (docked panel ↔ compact sheet) and resize the panel without an
        // updateNSView pass. Relying on autoresizing alone left the web view
        // at its old, wider size, so the page laid out for a wide viewport and
        // was visibly clipped inside the narrow panel.
        if let webContainer = container as? WebViewContainer {
            webContainer.webView = webView
        }
        webView.autoresizingMask = [.width, .height]
        webView.frame = container.bounds
        container.needsLayout = true
    }

    /// Container that keeps the hosted web view exactly its own size on every
    /// layout pass, and clips it so a transient mismatch can never bleed over
    /// the chat column.
    final class WebViewContainer: NSView {
        weak var webView: WKWebView?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            clipsToBounds = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            guard let webView, webView.superview === self else { return }
            if webView.frame != bounds {
                webView.frame = bounds
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate {
        let container = WebViewContainer()
        var controller: BrowserController?

        /// Keep navigation inside the panel; new-window requests become
        /// same-panel loads so popups don't escape the agent's view.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let controller else { return nil }
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                do {
                    _ = try BrowserURLValidator.validatedURL(
                        url.absoluteString,
                        filePolicy: controller.navigationFilePolicy)
                    webView.load(URLRequest(url: url))
                } catch {
                    controller.markFailed(error.localizedDescription)
                }
            }
            return nil
        }
    }
}
