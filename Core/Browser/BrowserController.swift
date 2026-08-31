import AppKit
import Foundation
import WebKit

extension Notification.Name {
    static let openBrowserPanel = Notification.Name("com.beetcode.openBrowserPanel")
}

/// Which WKWebView the docked panel is currently hosting.
@MainActor
final class BrowserPresentation: ObservableObject {
    static let shared = BrowserPresentation()
    @Published var controller = BrowserController.shared
}

/// In-app browser the agent can control.
///
/// Mac Chat/Code share one default WKWebView. Each specialist bot computer
/// gets its own controller and persistent `WKWebsiteDataStore`, so cookies
/// and logins never leak across bots or into the user's browser. Mutating
/// actions still go through PermissionGate at the tool layer.
///
/// Extraction helpers (`extractText`, `extractLinks`, `pageInfo`) are pure
/// JavaScript snippets; the JS escaping in `jsLiteral` is the security
/// boundary between agent-supplied strings and page execution.
@MainActor
final class BrowserController: ObservableObject {

    /// Singleton handle. Lazily created under a lock so the reference is
    /// reachable from any actor; the WKWebView itself is only ever touched
    /// through MainActor-isolated methods (tools hop via @MainActor Tasks).
    private static let sharedLock = NSLock()
    private static nonisolated(unsafe) var sharedInstance: BrowserController?
    private static nonisolated(unsafe) var botInstances: [UUID: BrowserController] = [:]

    static var shared: BrowserController {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = sharedInstance { return existing }
        let created = BrowserController(session: nil)
        sharedInstance = created
        return created
    }

    static func controller(for session: BrowserSession) -> BrowserController {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = botInstances[session.id] { return existing }
        let created = BrowserController(session: session)
        botInstances[session.id] = created
        return created
    }

    static func controller(for session: BrowserSession?) -> BrowserController {
        if let session { return controller(for: session) }
        return shared
    }

    private let session: BrowserSession?
    private var storedWebView: WKWebView?
    private var navigationRelay: NavigationRelay?

    /// Browser downloads are intentionally separate from WKWebView's page
    /// navigation. A clicked binary (for example a Hugging Face `.gguf`)
    /// must be streamed to disk instead of replacing the page with a forever
    /// loading download response. The session is ephemeral so credentials
    /// never outlive the app; the active bot's matching WebKit cookies are
    /// copied onto the request below.
    private static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    var webView: WKWebView { ensureWebView() }

    /// Shown in the docked panel chrome. Empty for the shared Mac browser.
    var ownerLabel: String { session?.name ?? "" }

    @Published var currentURL: URL?
    @Published var title: String = ""
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var lastAgentAction: String?

    /// Active `file://` policy for in-page navigations. Agent `open` sets
    /// `.confined`; the user address bar sets `.allowAny`.
    private(set) var navigationFilePolicy: BrowserURLValidator.FilePolicy = .refuse

    /// Test seam: tools check this instead of asserting UI state.
    private(set) var navigationCount = 0

    /// WKWebView is MainActor-only on Xcode 26/27 SDKs. The singleton can be
    /// *referenced* off-main (lock-backed); the view is created the first
    /// time a MainActor method actually needs it.
    nonisolated private init(session: BrowserSession?) {
        self.session = session
    }

    /// Makes this the panel's active WebView. Navigate also opens the panel.
    func reveal(openPanel: Bool = true) {
        BrowserPresentation.shared.controller = self
        if openPanel {
            NotificationCenter.default.post(name: .openBrowserPanel, object: nil)
        }
    }

    @MainActor
    private func ensureWebView() -> WKWebView {
        if let storedWebView { return storedWebView }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if let session {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: session.id)
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = AppIdentity.browserUserAgent
        let relay = NavigationRelay(owner: self)
        view.navigationDelegate = relay
        navigationRelay = relay
        storedWebView = view
        return view
    }

    // MARK: Navigation

    @discardableResult
    func open(_ urlString: String, filePolicy: BrowserURLValidator.FilePolicy = .allowAny) throws -> URL {
        let url = try BrowserURLValidator.validatedURL(urlString, filePolicy: filePolicy)
        navigationFilePolicy = filePolicy
        navigationCount += 1
        isLoading = true
        lastError = nil
        webView.load(URLRequest(url: url))
        currentURL = url
        return url
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    /// Streams an HTTP(S) resource into the current workspace. This is the
    /// explicit download primitive for the assistant: navigating to a binary
    /// URL is useful for inspection, but it is not a download and gives the
    /// model no completion signal. The returned path is the authoritative
    /// on-disk result, after the temporary URL has been moved atomically.
    func download(
        _ urlString: String,
        workspace: Workspace,
        directory: String? = nil,
        filename: String? = nil
    ) async throws -> URL {
        let url = try BrowserURLValidator.validatedURL(urlString, filePolicy: .refuse)
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw BrowserError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        request.setValue(AppIdentity.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request = await requestByAddingMatchingCookies(to: request, host: url.host)

        let (temporaryURL, response) = try await Self.downloadSession.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            try? FileManager.default.removeItem(at: temporaryURL)
            throw BrowserError.downloadFailed("The server returned HTTP \(status).")
        }

        // A login page or rate-limit page can still return HTTP 200. Never
        // report that HTML as a successful model/file download; the caller
        // needs a truthful failure so the assistant can retry with the page's
        // actual direct link or ask for credentials.
        if let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("text/html") {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw BrowserError.downloadFailed("The server returned an HTML page instead of a file.")
        }

        let suggested = Self.downloadFilename(
            response: response,
            requested: filename,
            sourceURL: url)
        let relativeDirectory = directory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let relativePath: String
        if let relativeDirectory, !relativeDirectory.isEmpty {
            relativePath = URL(fileURLWithPath: relativeDirectory)
                .appendingPathComponent(suggested, isDirectory: false).path
        } else {
            relativePath = ".beetcode/downloads/\(suggested)"
        }
        let requestedDestination = try workspace.resolve(relativePath, access: .write).url
        let destination = Self.uniqueDestination(for: requestedDestination)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw BrowserError.downloadFailed("Could not save the downloaded file: \(error.localizedDescription)")
        }

        noteAgentAction("Downloaded \(destination.lastPathComponent)")
        lastError = nil
        return destination
    }

    private func requestByAddingMatchingCookies(to request: URLRequest, host: String?) async -> URLRequest {
        guard let host, !host.isEmpty else { return request }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
        guard !matching.isEmpty else { return request }
        var request = request
        let fields = HTTPCookie.requestHeaderFields(with: matching)
        for (name, value) in fields { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private static func downloadFilename(
        response: URLResponse,
        requested: String?,
        sourceURL: URL
    ) -> String {
        let headerName = "Content-Disposition"
        let headerValue = (response as? HTTPURLResponse)?.allHeaderFields.first {
            String(describing: $0.key).caseInsensitiveCompare(headerName) == .orderedSame
        }.map { String(describing: $0.value) }
        let headerFilename = headerValue?.split(separator: ";").dropFirst().compactMap { part -> String? in
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard item.lowercased().hasPrefix("filename") else { return nil }
            return item.split(separator: "=", maxSplits: 1).last.map(String.init)
        }.first
        let raw = requested ?? headerFilename ?? sourceURL.lastPathComponent
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            .removingPercentEncoding ?? raw
        let pathComponent = URL(fileURLWithPath: unquoted).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()[]"))
        let clean = String(pathComponent.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." { return "download" }
        return String(clean.prefix(180))
    }

    private static func uniqueDestination(for requested: URL) -> URL {
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let ext = requested.pathExtension
        let stem = ext.isEmpty ? requested.lastPathComponent : requested.deletingPathExtension().lastPathComponent
        for index in 1...10_000 {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = requested.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return requested.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)")
    }

    /// Blocks until loading settles or the deadline passes. Bounded so a
    /// tool call can never hang the agent loop.
    func waitForLoad(timeout: TimeInterval = 12) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isLoading, Date() < deadline {
            // Navigation events come from BrowserController's own delegate,
            // so agent tools settle even when the docked panel is not mounted.
            // readyState is a fallback for about:blank / cached loads that
            // may not fire didStart.
            if let state = try? await webView.evaluateJavaScript("document.readyState") as? String,
               state == "interactive" || state == "complete" {
                isLoading = false
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // One grace settle for post-load JS activity.
        try? await Task.sleep(for: .milliseconds(250))
    }

    // MARK: JavaScript evaluation

    /// Evaluates a caller-controlled JS expression. Returns the stringified
    /// result. Errors surface as thrown `BrowserError`.
    func evaluate(_ script: String) async throws -> String {
        do {
            let result = try await webView.evaluateJavaScript(script)
            return Self.stringify(result)
        } catch {
            throw BrowserError.scriptFailed(String(describing: error).prefix(300).description)
        }
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: value)
    }

    // MARK: Page extraction (agent-facing, bounded)

    /// Visible text of the page, truncated for prompt budgets.
    func extractText(limit: Int = 12_000) async throws -> String {
        let text = try await evaluate("document.body ? document.body.innerText : ''")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "\n…[truncated]" : trimmed
    }

    struct PageLink: Sendable, Equatable {
        var text: String
        var href: String
    }

    /// A compact, model-facing accessibility-style description of an
    /// interactive DOM node. `ref` is scoped to the current document and is
    /// stable across repeated observations while that node remains mounted.
    struct InteractiveElement: Codable, Sendable, Equatable {
        var ref: String
        var role: String
        var name: String
        var tag: String
        var type: String
        var value: String
        var href: String
        var disabled: Bool
        var checked: Bool?
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    /// All links on the page: visible text + resolved URL. Capped so a
    /// link-farm page cannot blow up the tool output.
    func extractLinks(limit: Int = 60) async throws -> [PageLink] {
        let js = """
        (() => {
          const out = [];
          const anchors = document.querySelectorAll('a[href]');
          for (let i = 0; i < anchors.length && out.length < \(limit); i++) {
            const a = anchors[i];
            const text = (a.innerText || a.title || '').trim().slice(0, 120);
            out.push({ text: text, href: a.href });
          }
          return out;
        })()
        """
        let raw = try await evaluate(js)
        guard let data = raw.data(using: .utf8),
              let entries = try? JSONDecoder().decode([LinkWire].self, from: data)
        else { return [] }
        return entries.map { PageLink(text: $0.text, href: $0.href) }
    }

    private struct LinkWire: Codable {
        var text: String
        var href: String
    }

    /// Returns visible interactive elements with document-scoped references,
    /// similar to the indexed accessibility snapshots used by browser-use and
    /// Hermes. References fail closed after a navigation instead of silently
    /// resolving to a different element on the new page.
    func extractInteractiveElements(limit: Int = 80) async throws -> [InteractiveElement] {
        let boundedLimit = min(max(limit, 1), 200)
        let js = """
        (() => {
          \(Self.referenceRegistryPrelude)
          const selector = 'a[href],button,input:not([type="hidden"]),textarea,select,[role],[contenteditable="true"],[tabindex]';
          const candidates = Array.from(document.querySelectorAll(selector));
          const out = [];
          const roleFor = (el) => {
            const explicit = (el.getAttribute('role') || '').trim();
            if (explicit) return explicit;
            const tag = el.tagName.toLowerCase();
            if (tag === 'a') return 'link';
            if (tag === 'button') return 'button';
            if (tag === 'textarea') return 'textbox';
            if (tag === 'select') return 'combobox';
            if (tag === 'input') {
              const type = (el.type || 'text').toLowerCase();
              if (type === 'checkbox') return 'checkbox';
              if (type === 'radio') return 'radio';
              if (type === 'submit' || type === 'button') return 'button';
              return 'textbox';
            }
            return 'interactive';
          };
          const nameFor = (el) => {
            const labelledBy = (el.getAttribute('aria-labelledby') || '').trim();
            const labelled = labelledBy.split(/\\s+/).filter(Boolean)
              .map(id => document.getElementById(id)?.innerText || '')
              .join(' ').trim();
            return (el.getAttribute('aria-label') || labelled || el.innerText ||
              el.getAttribute('title') || el.getAttribute('placeholder') ||
              el.getAttribute('name') || el.value || '').replace(/\\s+/g, ' ').trim().slice(0, 160);
          };
          for (const el of candidates) {
            if (out.length >= \(boundedLimit)) break;
            const rect = el.getBoundingClientRect();
            const style = getComputedStyle(el);
            if (rect.width < 1 || rect.height < 1 || style.display === 'none' ||
                style.visibility === 'hidden' || Number(style.opacity) === 0) continue;
            const ref = assignBeetRef(el);
            const type = (el.getAttribute('type') || '').toLowerCase();
            let value = '';
            if ('value' in el) value = type === 'password' ? '(redacted)' : String(el.value || '').slice(0, 120);
            out.push({
              ref, role: roleFor(el), name: nameFor(el), tag: el.tagName.toLowerCase(), type,
              value, href: el.href || '', disabled: Boolean(el.disabled || el.getAttribute('aria-disabled') === 'true'),
              checked: ('checked' in el) ? Boolean(el.checked) : null,
              x: Math.round(rect.x), y: Math.round(rect.y),
              width: Math.round(rect.width), height: Math.round(rect.height)
            });
          }
          return out;
        })()
        """
        let raw = try await evaluate(js)
        guard let data = raw.data(using: .utf8),
              let elements = try? JSONDecoder().decode([InteractiveElement].self, from: data)
        else { return [] }
        return elements
    }

    nonisolated static func renderInteractiveElements(_ elements: [InteractiveElement]) -> String {
        guard !elements.isEmpty else { return "(no visible interactive elements found)" }
        return elements.map { element in
            let cleanName = element.name.replacingOccurrences(of: "\n", with: " ")
            var parts = ["[\(element.ref)]", element.role]
            if !cleanName.isEmpty { parts.append("\"\(cleanName)\"") }
            if !element.value.isEmpty, element.value != cleanName {
                parts.append("value \"\(element.value)\"")
            }
            if !element.href.isEmpty { parts.append("→ \(element.href)") }
            parts.append("at (\(Int(element.x + element.width / 2)),\(Int(element.y + element.height / 2)))")
            if element.disabled { parts.append("[disabled]") }
            if element.checked == true { parts.append("[checked]") }
            return parts.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// True when a page is loaded or loading.
    var hasOpenPage: Bool { webView.url != nil || currentURL != nil }

    /// One-line summary of where the browser is.
    func pageInfo() -> String {
        var parts: [String] = []
        if let session { parts.append("browser: \(session.name)") }
        if let url = currentURL ?? webView.url { parts.append("url: \(url.absoluteString)") }
        if !title.isEmpty { parts.append("title: \(title)") }
        if isLoading { parts.append("(still loading)") }
        return parts.joined(separator: " | ")
    }

    // MARK: Interaction

    /// Clicks the first element matching a CSS selector. Returns a
    /// human-readable confirmation (or throws when nothing matches).
    /// Clicks the first element matching a CSS selector. Returns a
    /// human-readable confirmation (or throws when nothing matches).
    func click(selector: String) async throws -> String {
        let js = """
        (() => {
          \(Self.highlightPrelude)
          const el = document.querySelector(\(Self.jsLiteral(selector)));
          if (!el) return { clicked: false };
          el.scrollIntoView({ block: 'center' });
          highlightBeetElement(el);
          el.click();
          return { clicked: true, tag: el.tagName.toLowerCase() };
        })()
        """
        let raw = try await evaluate(js)
        if raw.contains("\"clicked\":true") {
            noteAgentAction("Clicked \(selector)")
            return "clicked element matching \(selector)"
        }
        throw BrowserError.noSuchElement(selector)
    }

    /// Clicks a node from the latest `browser_read {what:"elements"}`
    /// observation. A reference from another document is rejected as stale.
    func click(ref: String) async throws -> String {
        let js = """
        (() => {
          \(Self.referenceRegistryPrelude)
          \(Self.highlightPrelude)
          const requested = \(Self.jsLiteral(ref));
          if (!requested.startsWith(beetState.token + ':')) return { clicked: false, stale: true };
          const el = Array.from(document.querySelectorAll('*')).find(node => node[beetRefKey] === requested);
          if (!el || !el.isConnected) return { clicked: false, stale: true };
          if (el.disabled || el.getAttribute('aria-disabled') === 'true') return { clicked: false, disabled: true };
          el.scrollIntoView({ block: 'center', inline: 'nearest' });
          highlightBeetElement(el);
          el.click();
          return { clicked: true, tag: el.tagName.toLowerCase() };
        })()
        """
        let raw = try await evaluate(js)
        if raw.contains("\"clicked\":true") { noteAgentAction("Clicked [\(ref)]"); return "clicked [\(ref)]" }
        if raw.contains("\"disabled\":true") { throw BrowserError.disabledElement(ref) }
        throw BrowserError.staleReference(ref)
    }

    /// Clicks the first clickable element whose visible text contains the
    /// given string (case-insensitive). More natural for agents than CSS.
    func clickByText(_ text: String) async throws -> String {
        let js = """
        (() => {
          \(Self.highlightPrelude)
          const needle = \(Self.jsLiteral(text)).toLowerCase();
          const candidates = document.querySelectorAll('a, button, [role="button"], input[type="submit"], [onclick]');
          for (const el of candidates) {
            const label = (el.innerText || el.value || '').toLowerCase();
            if (label.includes(needle)) {
              el.scrollIntoView({ block: 'center' });
              highlightBeetElement(el);
              el.click();
              return { clicked: true, tag: el.tagName.toLowerCase(), label: (el.innerText || el.value || '').slice(0, 80) };
            }
          }
          return { clicked: false };
        })()
        """
        let raw = try await evaluate(js)
        if raw.contains("\"clicked\":true") {
            noteAgentAction("Clicked “\(text)”")
            return "clicked element containing text: \(text)"
        }
        throw BrowserError.noSuchElement(text)
    }

    /// Types into the first field matching a CSS selector.
    func type(text: String, into selector: String, submit: Bool = false) async throws -> String {
        let js = """
        (() => {
          \(Self.highlightPrelude)
          \(Self.assignValuePrelude)
          const el = document.querySelector(\(Self.jsLiteral(selector)));
          if (!el) return { typed: false };
          el.focus();
          highlightBeetElement(el);
          if (!assignBeetValue(el, \(Self.jsLiteral(text)))) return { typed: false, unsupported: true };
          \(Self.submitPrelude(submit))
          return { typed: true };
        })()
        """
        let raw = try await evaluate(js)
        if raw.contains("\"typed\":true") {
            noteAgentAction("Typed into \(selector)")
            return submit ? "typed into \(selector) and submitted" : "typed into \(selector)"
        }
        if raw.contains("\"unsupported\":true") { throw BrowserError.unsupportedElement(selector) }
        throw BrowserError.noSuchElement(selector)
    }

    /// Types into a document-scoped element reference. Uses the native value
    /// setter when available so controlled React-style inputs receive the same
    /// input/change events as selector-based typing.
    func type(text: String, intoRef ref: String, submit: Bool = false) async throws -> String {
        let js = """
        (() => {
          \(Self.referenceRegistryPrelude)
          \(Self.highlightPrelude)
          \(Self.assignValuePrelude)
          const requested = \(Self.jsLiteral(ref));
          if (!requested.startsWith(beetState.token + ':')) return { typed: false, stale: true };
          const el = Array.from(document.querySelectorAll('*')).find(node => node[beetRefKey] === requested);
          if (!el || !el.isConnected) return { typed: false, stale: true };
          if (el.disabled || el.getAttribute('aria-disabled') === 'true') return { typed: false, disabled: true };
          el.focus();
          highlightBeetElement(el);
          if (!assignBeetValue(el, \(Self.jsLiteral(text)))) return { typed: false, unsupported: true };
          \(Self.submitPrelude(submit))
          return { typed: true };
        })()
        """
        let raw = try await evaluate(js)
        if raw.contains("\"typed\":true") {
            noteAgentAction("Typed into [\(ref)]")
            return submit ? "typed into [\(ref)] and submitted" : "typed into [\(ref)]"
        }
        if raw.contains("\"disabled\":true") { throw BrowserError.disabledElement(ref) }
        if raw.contains("\"unsupported\":true") { throw BrowserError.unsupportedElement(ref) }
        throw BrowserError.staleReference(ref)
    }

    /// Scroll the page or a referenced element. Positive dy moves down.
    func scroll(dx: Int = 0, dy: Int, ref: String? = nil) async throws -> String {
        let js: String
        if let ref {
            js = """
            (() => {
              \(Self.referenceRegistryPrelude)
              \(Self.highlightPrelude)
              const requested = \(Self.jsLiteral(ref));
              if (!requested.startsWith(beetState.token + ':')) return { scrolled: false, stale: true };
              const el = Array.from(document.querySelectorAll('*')).find(node => node[beetRefKey] === requested);
              if (!el || !el.isConnected) return { scrolled: false, stale: true };
              highlightBeetElement(el);
              const target = el.scrollHeight > el.clientHeight ? el : (el.closest('[style*=overflow], .overflow-auto, .overflow-y-auto') || window);
              if (target === window) window.scrollBy(\(dx), \(dy));
              else target.scrollBy(\(dx), \(dy));
              return { scrolled: true };
            })()
            """
        } else {
            js = """
            (() => {
              window.scrollBy(\(dx), \(dy));
              return { scrolled: true };
            })()
            """
        }
        let raw = try await evaluate(js)
        if raw.contains("\"stale\":true") { throw BrowserError.staleReference(ref ?? "") }
        noteAgentAction("Scrolled \(dy > 0 ? "down" : "up")")
        var result = "scrolled dx=\(dx) dy=\(dy)"
        if let ref { result += " using [\(ref)]" }
        return result
    }

    /// Snapshot of the visible page, saved as PNG.
    func snapshot(to fileURL: URL) async throws -> URL {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 1280)
        let captured: SnapshotImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { snapshot, error in
                if let snapshot {
                    continuation.resume(returning: SnapshotImage(image: snapshot))
                } else {
                    continuation.resume(throwing: BrowserError.snapshotFailed)
                }
            }
        }
        let image = captured.image
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw BrowserError.snapshotFailed }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: fileURL)
        return fileURL
    }

    /// AppKit images are main-actor objects, but Swift 6 models continuation
    /// results as crossing an actor boundary. The wrapper documents that the
    /// value never leaves this MainActor controller while satisfying the
    /// Xcode 16.4 compiler used by CI.
    private struct SnapshotImage: @unchecked Sendable {
        let image: NSImage
    }

    // MARK: JS string safety

    /// Escapes an agent-supplied string into a safe JS string literal.
    /// This is the ONLY path from tool arguments into page JavaScript.
    /// Pure — no actor isolation needed, callable from any context.
    nonisolated static func jsLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    /// Shared by element observation and reference actions. The token is born
    /// inside the page's JavaScript world, so a full navigation necessarily
    /// creates a new scope and makes every prior ref stale.
    private nonisolated static let referenceRegistryPrelude = """
        const beetStateKey = '__beetcodeAgentRefsV1';
        const beetRefKey = '__beetcodeAgentRefV1';
        let beetState = window[beetStateKey];
        if (!beetState || beetState.document !== document) {
          beetState = {
            document,
            token: 'b' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7),
            counter: 0
          };
          Object.defineProperty(window, beetStateKey, { value: beetState, configurable: true });
        }
        const assignBeetRef = (el) => {
          if (!el[beetRefKey]) {
            const value = beetState.token + ':e' + (++beetState.counter);
            Object.defineProperty(el, beetRefKey, { value, configurable: true });
          }
          return el[beetRefKey];
        };
        """

    private nonisolated static let highlightPrelude = """
        const highlightBeetElement = (el) => {
          if (!el || !el.style) return;
          el.style.setProperty('outline', '3px solid #b8b8b8', 'important');
          el.style.setProperty('outline-offset', '2px', 'important');
          setTimeout(() => {
            el.style.removeProperty('outline');
            el.style.removeProperty('outline-offset');
          }, 900);
        };
        """

    private nonisolated static let assignValuePrelude = """
        const assignBeetValue = (el, nextValue) => {
          if (el.isContentEditable) {
            el.textContent = nextValue;
          } else if ('value' in el) {
            const prototype = Object.getPrototypeOf(el);
            const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set
              || Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set
              || Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')?.set;
            if (setter) setter.call(el, nextValue); else el.value = nextValue;
          } else {
            return false;
          }
          el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: nextValue }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        };
        """

    private nonisolated static func submitPrelude(_ submit: Bool) -> String {
        guard submit else { return "" }
        return """
          el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
          el.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
          if (el.form) {
            if (typeof el.form.requestSubmit === 'function') el.form.requestSubmit();
            else el.form.submit();
          }
        """
    }

    func noteAgentAction(_ text: String) {
        lastAgentAction = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if lastAgentAction == text { lastAgentAction = nil }
        }
    }

    enum BrowserError: Error, LocalizedError {
        case emptyURL
        case invalidURL(String)
        case fileOutsideWorkspace(String)
        case scriptFailed(String)
        case noSuchElement(String)
        case staleReference(String)
        case disabledElement(String)
        case unsupportedElement(String)
        case downloadFailed(String)
        case snapshotFailed

        var errorDescription: String? {
            switch self {
            case .emptyURL: "No URL provided."
            case .invalidURL(let raw): "Invalid or non-http(s) URL: \(raw)"
            case .fileOutsideWorkspace(let path): "Refused to open '\(path)' — file URLs must stay inside the open workspace."
            case .scriptFailed(let detail): "Page script failed: \(detail)"
            case .noSuchElement(let query): "No element found for: \(query)"
            case .staleReference(let ref): "Element reference '\(ref)' is stale. Call browser_read with what=elements and retry with a fresh ref."
            case .disabledElement(let ref): "Element '\(ref)' is disabled."
            case .unsupportedElement(let ref): "Element '\(ref)' does not accept text input."
            case .downloadFailed(let detail): "Download failed: \(detail)"
            case .snapshotFailed: "Could not capture the page snapshot."
            }
        }
    }
}

/// Scheme + confinement policy for agent and chrome navigations.
/// `file://` is a workspace-escape if left unrestricted (`file:///etc/passwd`).
enum BrowserURLValidator: Sendable {
    enum FilePolicy: Sendable {
        /// User-typed address bar: any local file the user asked to open.
        case allowAny
        /// Agent tools: `file://` only when the path is inside the workspace.
        case confined(Workspace)
        /// Reject `file://` entirely.
        case refuse
    }

    static func validatedURL(_ urlString: String, filePolicy: FilePolicy) throws -> URL {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw BrowserController.BrowserError.emptyURL }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            throw BrowserController.BrowserError.invalidURL(raw)
        }
        switch scheme {
        case "http", "https":
            return url
        case "file":
            switch filePolicy {
            case .allowAny:
                return url
            case .refuse:
                throw BrowserController.BrowserError.invalidURL(raw)
            case .confined(let workspace):
                do {
                    _ = try workspace.resolve(url.path, access: .read)
                    return url
                } catch {
                    throw BrowserController.BrowserError.fileOutsideWorkspace(url.path)
                }
            }
        default:
            throw BrowserController.BrowserError.invalidURL(raw)
        }
    }
}

/// Bridges delegate callbacks into BrowserController's @Published state.
@MainActor
extension BrowserController {
    func markStarted(_ url: URL?) {
        isLoading = true
        lastError = nil
        if let url { currentURL = url }
    }

    func markFinished(_ url: URL?, title: String?) {
        isLoading = false
        if let url { currentURL = url }
        if let title { self.title = title }
    }

    func markFailed(_ message: String) {
        isLoading = false
        lastError = message
    }
}

/// Lives on the owning WKWebView so load events are delivered even when the
/// docked browser panel is not mounted.
@MainActor
private final class NavigationRelay: NSObject, WKNavigationDelegate {
    weak var owner: BrowserController?

    init(owner: BrowserController) {
        self.owner = owner
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        owner?.markStarted(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.title") { [weak self, weak webView] result, _ in
            let title = (result as? String) ?? ""
            Task { @MainActor in
                self?.owner?.markFinished(webView?.url, title: title)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        owner?.markFailed(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        owner?.markFailed(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let owner, let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        do {
            _ = try BrowserURLValidator.validatedURL(
                url.absoluteString,
                filePolicy: owner.navigationFilePolicy)
            decisionHandler(.allow)
        } catch {
            owner.markFailed(error.localizedDescription)
            decisionHandler(.cancel)
        }
    }
}
