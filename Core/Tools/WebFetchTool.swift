import Darwin
import Foundation

/// Bounded, approval-gated HTTP GET so the agent can read docs without
/// opening the in-app browser. `file://` / `javascript:` / `data:` are
/// rejected — this is not a workspace-escape hatch.
enum WebFetchError: Error, LocalizedError {
    case invalidURL(String)
    case blockedHost(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw): "Invalid or non-http(s) URL: \(raw)"
        case .blockedHost(let host): "Refusing to fetch private or loopback host: \(host)"
        }
    }
}

enum WebFetchPolicy {
    static func validatedURL(_ raw: String) throws -> URL {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.missingArgument("url") }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw WebFetchError.invalidURL(trimmed)
        }
        guard scheme == "http" || scheme == "https" else {
            throw WebFetchError.invalidURL(trimmed)
        }
        if let host = url.host, isBlockedHost(host) {
            throw WebFetchError.blockedHost(host)
        }
        return url
    }

    static func isBlockedHost(_ host: String) -> Bool {
        let lower = host.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower == "metadata.google.internal" {
            return true
        }
        // Numeric hosts reach loopback without ever looking like an IP to a
        // string check: 2130706433, 0x7f000001, 127.1, 0177.0.0.1. Canonicalize
        // every common encoding before deciding.
        if let ipv4 = parseIPv4(lower), isBlockedIPv4(ipv4) { return true }
        if let ipv6 = ipv6Bytes(lower), isBlockedIPv6(ipv6) { return true }
        return false
    }

    /// Resolves a host and returns the first blocked address, or nil when the
    /// host is public (or cannot be resolved — the fetch itself will report
    /// that failure). Closes the static malicious-DNS case; a DNS record that
    /// re-resolves between this probe and the connection is out of scope.
    static func blockedResolvedAddress(for host: String) -> String? {
        guard !host.isEmpty, let addresses = resolvedAddresses(host) else { return nil }
        return addresses.first { isBlockedHost($0) }
    }

    // MARK: Numeric address parsing

    /// Parses decimal/hex/octal IPv4 forms, including the 1–3 component
    /// shorthand (`127.1`, `10`, `0x7f000001`).
    private static func parseIPv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var value: UInt64 = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty else { return nil }
            let radix: Int
            let digits: Substring
            if part.hasPrefix("0x") || part.hasPrefix("0X") {
                radix = 16
                digits = part.dropFirst(2)
            } else if part.count > 1, part.hasPrefix("0") {
                radix = 8
                digits = part.dropFirst()
            } else {
                radix = 10
                digits = part
            }
            guard !digits.isEmpty, let number = UInt64(digits, radix: radix) else { return nil }
            if index < parts.count - 1 {
                guard number <= 0xFF else { return nil }
                value = (value << 8) | number
            } else {
                let remainingBytes = 4 - index
                guard number <= (UInt64(1) << (8 * remainingBytes)) - 1 else { return nil }
                value = (value << (8 * remainingBytes)) | number
            }
        }
        guard value <= UInt64(UInt32.max) else { return nil }
        return UInt32(value)
    }

    private static func isBlockedIPv4(_ value: UInt32) -> Bool {
        let a = UInt8((value >> 24) & 0xFF)
        let b = UInt8((value >> 16) & 0xFF)
        if a == 0 || a == 10 || a == 127 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && (64...127).contains(b) { return true } // CGNAT
        if a >= 224 { return true } // multicast + reserved
        return false
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func isBlockedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return true }               // ::
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true } // ::1
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }   // fe80::/10
        if bytes[0] & 0xFE == 0xFC { return true }                      // fc00::/7
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let v4 = (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
                | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
            return isBlockedIPv4(v4)
        }
        return false
    }

    private static func resolvedAddresses(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return nil }
        defer { if let result { freeaddrinfo(result) } }
        var addresses: [String] = []
        var pointer = result
        while let info = pointer {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr, info.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
            pointer = info.pointee.ai_next
        }
        return addresses.isEmpty ? nil : addresses
    }
}

/// Best-effort visible-text extraction. Not a browser — just enough to turn
/// a docs HTML page into something a model can read.
enum HTMLText {
    static func extract(_ raw: String, limit: Int) -> String {
        var text = raw
        // Drop script/style blocks first so their contents never leak.
        for tag in ["script", "style", "noscript"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[\\s\\S]*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        let collapsed = text
            .replacingOccurrences(of: "[ \\t\\f\\r]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "\n…[truncated]"
    }
}

struct WebFetchTool: AgentTool {
    let name = "web_fetch"
    let summary = "Fetch a public http(s) URL and return its visible text (bounded)"
    let risk = ToolRisk.execute
    let treatsErrorPrefixAsFailure = true

    let schemaText = """
        {"type":"object","properties":{
          "url":{"type":"string","description":"http(s) URL to fetch"},
          "limit":{"type":"integer","description":"Max characters to return (default 12000, max 24000)"}
        },"required":["url"]}
        """

    static let defaultLimit = 12_000
    static let hardLimit = 24_000
    static let maxBytes = 256 * 1024

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let raw = call.string("url") else { return .none }
        return .command("web_fetch \(raw)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let raw = call.string("url") else { throw ToolError.missingArgument("url") }
        let url = try WebFetchPolicy.validatedURL(raw)
        // A public DNS name can still point at loopback or an RFC1918 host.
        if let blocked = WebFetchPolicy.blockedResolvedAddress(for: url.host ?? "") {
            return "error: refusing to fetch private or loopback address \(blocked)"
        }
        let limit = min(max(call.int("limit") ?? Self.defaultLimit, 500), Self.hardLimit)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = ["User-Agent": AppIdentity.userAgent]
        let delegate = WebFetchRedirectGuard()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(from: url)
        } catch {
            return "error: fetch failed — \(error.localizedDescription)"
        }
        if let host = response.url?.host, WebFetchPolicy.isBlockedHost(host) {
            return "error: refused redirected host \(host)"
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            return "error: HTTP \(status) from \(url.absoluteString)"
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBytes {
                    return "error: response exceeded the \(Self.maxBytes) byte cap"
                }
            }
        } catch {
            return "error: fetch failed — \(error.localizedDescription)"
        }
        let rawText = String(decoding: data, as: UTF8.self)
        let type = (response.mimeType ?? "").lowercased()
        let body: String
        if type.contains("html") || rawText.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<!") {
            body = HTMLText.extract(rawText, limit: limit)
        } else {
            body = rawText.count > limit ? String(rawText.prefix(limit)) + "\n…[truncated]" : rawText
        }
        return "url: \(url.absoluteString)\nstatus: \(status)\n\n\(body)"
    }
}

/// Drops redirects onto loopback or RFC1918 hosts so web_fetch cannot be
/// used as an SSRF trampoline.
final class WebFetchRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, let host = url.host,
              !WebFetchPolicy.isBlockedHost(host),
              WebFetchPolicy.blockedResolvedAddress(for: host) == nil
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
