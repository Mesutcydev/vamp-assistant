import AppKit
import SwiftUI
import WebKit

/// Docked panel hosting the agent-controlled browser. Mac Chat/Code share one
/// WebView; a specialist bot session hosts that bot's isolated WebView instead.
struct BrowserPanelView: View {
    var onClose: () -> Void

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var presentation = BrowserPresentation.shared

    var body: some View {
        BrowserPanelChrome(
            onClose: onClose,
            controller: presentation.controller,
            computers: appState.botComputers.computers)
    }
}

private struct BrowserPanelChrome: View {
    var onClose: () -> Void

    @ObservedObject var controller: BrowserController
    let computers: [BotComputerRecord]
    @State private var urlDraft = ""
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Chrome row: back/forward/reload + URL field + close.
            HStack(spacing: 6) {
                Button { controller.back() } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Back")
                .accessibilityLabel("Back")
                .disabled(!controller.webView.canGoBack)

                Button { controller.forward() } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Forward")
                .accessibilityLabel("Forward")
                .disabled(!controller.webView.canGoForward)

                Button {
                    if controller.isLoading { controller.stop() }
                    else { controller.reload() }
                } label: {
                    if controller.isLoading {
                        Image(systemName: "xmark")
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help(controller.isLoading ? "Stop" : "Reload")
                .accessibilityLabel(controller.isLoading ? "Stop loading" : "Reload page")

                Menu {
                    Button("Vamp Assistant", systemImage: "sparkles") {
                        BrowserController.shared.reveal(openPanel: false)
                    }
                    if !computers.isEmpty { Divider() }
                    ForEach(computers) { computer in
                        Button(computer.name, systemImage: "person.crop.circle") {
                            BrowserController.controller(
                                for: BrowserSession(id: computer.id, name: computer.name))
                                .reveal(openPanel: false)
                        }
                    }
                } label: {
                    Label(controller.ownerLabel.isEmpty ? "Assistant" : controller.ownerLabel,
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surfaceInset, in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose the Assistant or a bot's private browser")

                TextField("Enter a URL or let the agent open one…", text: $urlDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .focused($urlFocused)
                    .layoutPriority(1)
                    .onSubmit {
                        let target = urlDraft.trimmingCharacters(in: .whitespaces)
                        if !target.isEmpty {
                            do {
                                _ = try controller.open(target)
                                urlFocused = false
                            } catch {
                                controller.lastError = error.localizedDescription
                            }
                        }
                    }

                Button {
                    if let url = controller.currentURL ?? controller.webView.url {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "safari")
                }
                .help("Open in Safari")
                .accessibilityLabel("Open in Safari")
                .disabled((controller.currentURL ?? controller.webView.url) == nil)

                PanelCloseButton(action: onClose)
            }
            .padding(10)

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
        .lfGlass()
        .onAppear { syncURLDraft() }
        .onChange(of: controller.currentURL) { _, newValue in
            if !urlFocused, let newValue {
                urlDraft = newValue.absoluteString
            }
        }
        .onChange(of: controller.ownerLabel) { _, _ in
            syncURLDraft()
        }
    }

    private var statusCaption: String {
        if controller.lastAgentAction != nil { return "Agent is controlling this page" }
        if !controller.ownerLabel.isEmpty { return "\(controller.ownerLabel)'s browser" }
        return "browser_* tools"
    }

    private func syncURLDraft() {
        if let current = controller.currentURL {
            urlDraft = current.absoluteString
        } else {
            urlDraft = ""
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
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate {
        let container = NSView()
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
