import Foundation
import Security

struct RemoteAPIClient {
    let baseURL: URL
    var token: String?

    /// Single-connection session so pipelined input stays ordered and snappy.
    private static let controlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Ordinary companion requests must not share a connection pool with
    /// long-lived screen, audio, and terminal streams. A dedicated ephemeral
    /// session prevents long streams from starving pairing and list refreshes.
    /// Waiting for connectivity is important on a real iPhone because the
    /// Local Network prompt and Tailscale route can settle after the request
    /// begins; the request timeout still bounds an unavailable Mac.
    private static let apiSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private static let streamSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 24 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    func pair(code: String) async throws -> RemotePairResponse {
        try await request("api/pair", method: "POST", body: ["code": code], authorized: false, timeout: 30)
    }

    func status() async throws -> RemoteStatus { try await request("api/status") }
    func sessions() async throws -> RemoteSessionEnvelope { try await request("api/sessions") }
    func models() async throws -> RemoteModelEnvelope { try await request("api/models") }
    func workspaces() async throws -> RemoteWorkspaceEnvelope { try await request("api/workspaces") }
    func openWorkspace(path: String) async throws -> RemoteWorkspaceAccepted {
        try await request("api/workspaces", method: "POST", body: ["path": path])
    }
    func createWorkspace(name: String, parentPath: String? = nil) async throws -> RemoteWorkspaceAccepted {
        var body: [String: Any] = ["name": name]
        if let parentPath, !parentPath.isEmpty { body["parentPath"] = parentPath }
        return try await request("api/workspaces", method: "POST", body: body)
    }
    func saveAPIKey(providerID: String, key: String) async throws -> RemoteAcceptedResponse {
        try await request("api/providers/key", method: "POST", body: ["providerID": providerID, "key": key], timeout: 30)
    }
    func botComputers() async throws -> RemoteBotComputerEnvelope { try await request("api/bot-computers") }
    func botRuns() async throws -> RemoteBotRunEnvelope { try await request("api/bot-runs") }
    func startBotRun(profileID: String, modelID: String?, prompt: String) async throws -> RemoteAcceptedResponse {
        var body: [String: Any] = ["profileID": profileID, "prompt": prompt]
        if let modelID, !modelID.isEmpty { body["modelID"] = modelID }
        return try await request("api/bot-runs", method: "POST", body: body)
    }
    func steerBotRun(_ id: UUID, message: String) async throws -> RemoteAcceptedResponse {
        try await request("api/bot-runs/\(id.uuidString)/steer", method: "POST", body: ["message": message])
    }
    func stopBotRun(_ id: UUID) async throws -> RemoteAcceptedResponse {
        try await request("api/bot-runs/\(id.uuidString)/stop", method: "POST", body: [:])
    }
    func orchestrateBots(modelID: String?, prompt: String) async throws -> RemoteAcceptedResponse {
        var body: [String: Any] = ["prompt": prompt]
        if let modelID, !modelID.isEmpty { body["modelID"] = modelID }
        return try await request("api/bot-workflows", method: "POST", body: body)
    }
    func approveBotRun(_ id: UUID, approved: Bool) async throws -> RemoteAcceptedResponse {
        try await request("api/bot-runs/\(id.uuidString)/\(approved ? "approve" : "decline")", method: "POST", body: [:])
    }
    func answerBotRun(_ id: UUID, answer: String) async throws -> RemoteAcceptedResponse {
        try await request("api/bot-runs/\(id.uuidString)/answer", method: "POST", body: ["answer": answer])
    }
    func resumeBotRun(_ id: UUID) async throws -> RemoteAcceptedResponse {
        try await request("api/bot-runs/\(id.uuidString)/resume", method: "POST", body: [:])
    }
    func refreshBotComputers() async throws -> RemoteBotComputerEnvelope { try await request("api/bot-computers/refresh", method: "POST", body: [:]) }
    func startBotComputer(_ id: UUID) async throws -> RemoteAcceptedResponse { try await request("api/bot-computers/\(id.uuidString)/start", method: "POST", body: [:]) }
    func stopBotComputer(_ id: UUID) async throws -> RemoteAcceptedResponse { try await request("api/bot-computers/\(id.uuidString)/stop", method: "POST", body: [:]) }
    func prepareBotComputers(profileID: String? = nil) async throws -> RemoteBotComputerEnvelope {
        var body: [String: Any] = [:]
        if let profileID, !profileID.isEmpty { body["profileID"] = profileID }
        return try await request("api/bot-computers", method: "POST", body: body, timeout: 30)
    }
    func clipboard() async throws -> RemoteClipboardSnapshot { try await request("api/clipboard") }
    func sharedFiles() async throws -> RemoteSharedFileEnvelope { try await request("api/files") }
    func controlStatus() async throws -> RemoteMacControlStatus { try await request("api/control") }
    func controlApplications() async throws -> RemoteMacApplicationEnvelope {
        try await request("api/control/apps")
    }

    func controlScreen(
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        resolution: RemoteStreamResolution = .balanced
    ) async throws -> RemoteMacControlFrame {
        var url = baseURL.appending(path: "api/control/screen")
        var queryItems = [URLQueryItem(name: "resolution", value: resolution.rawValue)]
        if let displayID {
            queryItems.append(URLQueryItem(name: "display", value: String(displayID)))
        }
        if let windowID {
            queryItems.append(URLQueryItem(name: "window", value: String(windowID)))
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        url = components?.url ?? url
        let request = try authorizedRequest(url: url, method: "GET")
        let (data, response) = try await Self.apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(RemoteErrorBody.self, from: data).error)
                ?? "Remote request failed (\(http.statusCode))."
            throw RemoteClientError.server(message)
        }
        return RemoteMacControlFrame(
            payload: .jpeg(data),
            imageWidth: headerInt(http, "X-Beet-Image-Width") ?? 1,
            imageHeight: headerInt(http, "X-Beet-Image-Height") ?? 1,
            displayX: headerDouble(http, "X-Beet-Display-X") ?? 0,
            displayY: headerDouble(http, "X-Beet-Display-Y") ?? 0,
            displayWidth: headerDouble(http, "X-Beet-Display-Width") ?? 1,
            displayHeight: headerDouble(http, "X-Beet-Display-Height") ?? 1)
    }

    func controlScreenStream(
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        resolution: RemoteStreamResolution = .high
    ) -> AsyncThrowingStream<RemoteMacControlFrame, Error> {
        var queryItems = [URLQueryItem(name: "resolution", value: resolution.rawValue)]
        if let displayID {
            queryItems.append(URLQueryItem(name: "display", value: String(displayID)))
        }
        if let windowID {
            queryItems.append(URLQueryItem(name: "window", value: String(windowID)))
        }
        return avcStream(path: "api/control/screen/stream", queryItems: queryItems)
    }

    // The command dictionaries are built fresh at each call site and handed
    // over wholesale, so they transfer into the nonisolated client rather than
    // being shared with the main actor.
    func sendControl(_ body: sending [String: Any]) async throws -> RemoteAcceptedResponse {
        try await controlRequest("api/control/input", body: body)
    }

    func sendControlBatch(_ commands: sending [[String: Any]]) async throws -> RemoteAcceptedResponse {
        try await controlRequest("api/control/input", body: ["commands": commands])
    }

    private func controlRequest(_ path: String, body: sending [String: Any]) async throws -> RemoteAcceptedResponse {
        var request = try authorizedRequest(url: baseURL.appending(path: path), method: "POST")
        request.timeoutInterval = 2
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Self.controlSession.data(for: request)
        return try decode(RemoteAcceptedResponse.self, data: data, response: response)
    }

    private func avcStream(
        path: String,
        queryItems: [URLQueryItem]
    ) -> AsyncThrowingStream<RemoteMacControlFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var url = baseURL.appending(path: path)
                    if !queryItems.isEmpty {
                        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        components?.queryItems = queryItems
                        url = components?.url ?? url
                    }
                    var request = try authorizedRequest(url: url, method: "GET")
                    request.timeoutInterval = 24 * 60 * 60
                    // Prefer mixed; older Macs may still send x-mixed-replace (URLSession may unwrap).
                    request.setValue(
                        "multipart/mixed, multipart/x-mixed-replace, video/avc",
                        forHTTPHeaderField: "Accept")

                    let chunks = Self.chunkStream(for: request, session: Self.streamSession)
                    var buffer = Data()
                    buffer.reserveCapacity(1024 * 1024)
                    var boundary = "beetframe"
                    var mode: StreamParseMode?
                    var partExpected: Int?
                    var partHeaders: [String: String] = [:]
                    let maxFrameBytes = 24 * 1024 * 1024
                    let maxBufferBytes = 32 * 1024 * 1024

                    for try await event in chunks {
                        try Task.checkCancellation()
                        switch event {
                        case .headers(let http):
                            guard (200..<300).contains(http.statusCode) else {
                                throw RemoteClientError.server("Stream HTTP \(http.statusCode)")
                            }
                            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                                .lowercased()
                            if contentType.contains("multipart") {
                                mode = .multipart
                                boundary = Self.multipartBoundary(from: http) ?? "beetframe"
                                buffer.removeAll(keepingCapacity: true)
                                partExpected = nil
                                partHeaders = [:]
                            } else if contentType.contains("video/avc")
                                        || contentType.contains("application/octet-stream") {
                                // URLSession unwraps multipart/x-mixed-replace into per-part
                                // responses. Each part arrives as headers + body.
                                mode = .unwrappedPart
                                partHeaders = Self.headerMap(from: http)
                                partExpected = Int(partHeaders["content-length"] ?? "")
                                buffer.removeAll(keepingCapacity: true)
                                if let expected = partExpected, expected <= 0 || expected > maxFrameBytes {
                                    throw RemoteClientError.invalidResponseReason(
                                        "bad part length \(partHeaders["content-length"] ?? "?")")
                                }
                            } else {
                                throw RemoteClientError.invalidResponseReason(
                                    "expected multipart or video/avc, got \(contentType.prefix(80))")
                            }
                        case .data(let data):
                            guard let mode else { continue }
                            switch mode {
                            case .multipart:
                                buffer.append(data)
                                while true {
                                    switch Self.consumeAVCFrame(
                                        from: &buffer,
                                        boundary: boundary,
                                        maxFrameBytes: maxFrameBytes
                                    ) {
                                    case .needMoreData:
                                        break
                                    case .frame(let frame):
                                        continuation.yield(frame)
                                        continue
                                    case .skip:
                                        continue
                                    case .ended:
                                        continuation.finish()
                                        return
                                    }
                                    break
                                }
                                if buffer.count > maxBufferBytes {
                                    let marker = Data("--\(boundary)".utf8)
                                    if let range = buffer.range(
                                        of: marker,
                                        in: buffer.index(after: buffer.startIndex)..<buffer.endIndex
                                    ) {
                                        buffer.removeSubrange(0..<range.lowerBound)
                                    } else {
                                        buffer.removeAll(keepingCapacity: true)
                                    }
                                }
                            case .unwrappedPart:
                                buffer.append(data)
                                guard let expected = partExpected else { continue }
                                guard buffer.count >= expected else { continue }
                                let body = buffer.prefix(expected)
                                buffer.removeAll(keepingCapacity: true)
                                partExpected = nil
                                if let frame = Self.frameFromAVCPart(headers: partHeaders, body: Data(body)) {
                                    continuation.yield(frame)
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum StreamParseMode {
        case multipart
        case unwrappedPart
    }

    private enum StreamEvent: Sendable {
        case headers(HTTPURLResponse)
        case data(Data)
    }

    private enum AVCConsumeResult {
        case needMoreData
        case frame(RemoteMacControlFrame)
        case skip(String)
        case ended
    }

    private static func headerMap(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name.lowercased()] = "\(value)"
        }
        return headers
    }

    private static func frameFromAVCPart(
        headers: [String: String],
        body: Data
    ) -> RemoteMacControlFrame? {
        let contentType = (headers["content-type"] ?? "video/avc").lowercased()
        guard contentType.contains("video/avc") || contentType.contains("application/octet-stream") else {
            return nil
        }
        let keyframe = (headers["x-beet-keyframe"] ?? "0") == "1"
        let paramsLength = Int(headers["x-beet-params-length"] ?? "0") ?? 0
        let parameterSets: Data?
        let avcc: Data
        if paramsLength > 0 {
            guard paramsLength < body.count else { return nil }
            parameterSets = Data(body.prefix(paramsLength))
            avcc = Data(body.suffix(from: body.startIndex.advanced(by: paramsLength)))
        } else if let encoded = headers["x-beet-parameter-sets"], !encoded.isEmpty,
                  let decoded = Data(base64Encoded: encoded) {
            parameterSets = decoded
            avcc = body
        } else {
            parameterSets = nil
            avcc = body
        }
        guard !avcc.isEmpty else { return nil }
        return RemoteMacControlFrame(
            payload: .h264(data: avcc, keyframe: keyframe, parameterSets: parameterSets),
            imageWidth: Int(headers["x-beet-image-width"] ?? "") ?? 1,
            imageHeight: Int(headers["x-beet-image-height"] ?? "") ?? 1,
            displayX: Double(headers["x-beet-display-x"] ?? "") ?? 0,
            displayY: Double(headers["x-beet-display-y"] ?? "") ?? 0,
            displayWidth: Double(headers["x-beet-display-width"] ?? "") ?? 1,
            displayHeight: Double(headers["x-beet-display-height"] ?? "") ?? 1)
    }

    private static func chunkStream(
        for request: URLRequest,
        session: URLSession
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
                let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
                init(_ continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) {
                    self.continuation = continuation
                }
                func urlSession(
                    _ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
                ) {
                    if let http = response as? HTTPURLResponse {
                        continuation.yield(.headers(http))
                        completionHandler(.allow)
                    } else {
                        continuation.finish(throwing: RemoteClientError.invalidResponse)
                        completionHandler(.cancel)
                    }
                }
                func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                    continuation.yield(.data(data))
                }
                func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                    if let error {
                        if (error as? URLError)?.code == .cancelled {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: error)
                        }
                    } else {
                        continuation.finish()
                    }
                }
            }

            let receiver = Receiver(continuation)
            let delegateSession = URLSession(
                configuration: session.configuration,
                delegate: receiver,
                delegateQueue: nil)
            let task = delegateSession.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                delegateSession.invalidateAndCancel()
            }
            task.resume()
        }
    }

    private static func multipartBoundary(from response: HTTPURLResponse) -> String? {
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                return String(trimmed.dropFirst("boundary=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private static func consumeAVCFrame(
        from buffer: inout Data,
        boundary: String,
        maxFrameBytes: Int
    ) -> AVCConsumeResult {
        let marker = Data("--\(boundary)".utf8)
        guard let first = buffer.range(of: marker) else { return .needMoreData }
        if first.lowerBound > 0 {
            buffer.removeSubrange(0..<first.lowerBound)
        }
        let afterOpen = marker.count
        guard buffer.count > afterOpen else { return .needMoreData }

        if buffer.count >= afterOpen + 2,
           buffer[afterOpen] == 0x2d, buffer[afterOpen + 1] == 0x2d {
            return .ended
        }

        let headerStart: Int
        if buffer.count > afterOpen + 1,
           buffer[afterOpen] == 0x0d, buffer[afterOpen + 1] == 0x0a {
            headerStart = afterOpen + 2
        } else {
            headerStart = afterOpen
        }

        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator, in: headerStart..<buffer.count) else {
            return .needMoreData
        }
        let headerData = buffer.subdata(in: headerStart..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            // Skip this boundary and try the next one.
            buffer.removeSubrange(0..<min(afterOpen + 2, buffer.count))
            return .skip("part headers not utf8")
        }
        var headers: [String: String] = [:]
        for line in headerText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard let lengthText = headers["content-length"], let length = Int(lengthText), length > 0 else {
            buffer.removeSubrange(0..<headerEnd.upperBound)
            return .skip("missing content-length")
        }
        if length > maxFrameBytes {
            // Advance past this part once fully buffered, then skip.
            let bodyEnd = headerEnd.upperBound + length
            guard buffer.count >= bodyEnd else { return .needMoreData }
            var consumed = bodyEnd
            if buffer.count >= consumed + 2,
               buffer[consumed] == 0x0d, buffer[consumed + 1] == 0x0a {
                consumed += 2
            }
            buffer.removeSubrange(0..<consumed)
            return .skip("frame \(length)B exceeds \(maxFrameBytes)B")
        }
        let bodyStart = headerEnd.upperBound
        let bodyEnd = bodyStart + length
        guard buffer.count >= bodyEnd else { return .needMoreData }
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        var consumed = bodyEnd
        if buffer.count >= consumed + 2,
           buffer[consumed] == 0x0d, buffer[consumed + 1] == 0x0a {
            consumed += 2
        }
        buffer.removeSubrange(0..<consumed)

        let contentType = (headers["content-type"] ?? "video/avc").lowercased()
        guard contentType.contains("video/avc") || contentType.contains("application/octet-stream") else {
            return .skip("unexpected part type \(contentType)")
        }
        guard let frame = frameFromAVCPart(headers: headers, body: body) else {
            return .skip("unreadable avc part")
        }
        return .frame(frame)
    }

    func controlAudio() -> AsyncThrowingStream<RemoteMacAudioChunk, Error> {
        sseStream(path: "api/control/audio") { payload in
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let sampleRate = object["sr"] as? NSNumber,
                  let channelCount = object["ch"] as? NSNumber,
                  let encoded = object["pcm"] as? String,
                  let pcmData = Data(base64Encoded: encoded),
                  sampleRate.doubleValue >= 8_000,
                  sampleRate.doubleValue <= 192_000,
                  (1...8).contains(channelCount.intValue),
                  !pcmData.isEmpty,
                  pcmData.count <= 256 * 1024 else {
                throw RemoteClientError.invalidResponse
            }
            return RemoteMacAudioChunk(
                sampleRate: sampleRate.doubleValue,
                channelCount: channelCount.intValue,
                pcmData: pcmData
            )
        }
    }

    func openTerminal(cols: Int = 80, rows: Int = 24) async throws -> RemoteAcceptedResponse {
        try await terminalRequest(action: "open", cols: cols, rows: rows)
    }

    func sendTerminalInput(_ data: Data) async throws -> RemoteAcceptedResponse {
        guard !data.isEmpty, data.count <= 16 * 1024 else { throw RemoteClientError.invalidResponse }
        return try await terminalRequest(action: "input", data: data.base64EncodedString())
    }

    func resizeTerminal(cols: Int, rows: Int) async throws -> RemoteAcceptedResponse {
        try await terminalRequest(action: "resize", cols: cols, rows: rows)
    }

    func closeTerminal() async throws -> RemoteAcceptedResponse {
        try await terminalRequest(action: "close")
    }

    func terminalOutput() -> AsyncThrowingStream<Data, Error> {
        sseStream(path: "api/control/terminal/output") { payload in
            guard payload.count <= 64 * 1024,
                  let event = try? JSONDecoder().decode(RemoteTerminalOutputPayload.self, from: payload),
                  let bytes = event.bytes,
                  !bytes.isEmpty else {
                throw RemoteClientError.invalidResponse
            }
            return bytes
        }
    }

    private func terminalRequest(
        action: String,
        cols: Int? = nil,
        rows: Int? = nil,
        data: String? = nil
    ) async throws -> RemoteAcceptedResponse {
        var body: [String: Any] = ["action": action]
        if let cols { body["cols"] = min(max(cols, 1), 240) }
        if let rows { body["rows"] = min(max(rows, 1), 120) }
        if let data { body["data"] = data }
        return try await request("api/control/terminal", method: "POST", body: body, timeout: 5)
    }

    private func sseStream<Value: Sendable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        maxPayloadBytes: Int = 512 * 1024,
        decode: @escaping @Sendable (Data) throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var url = baseURL.appending(path: path)
                    if !queryItems.isEmpty {
                        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        components?.queryItems = queryItems
                        url = components?.url ?? url
                    }
                    var request = try authorizedRequest(url: url, method: "GET")
                    request.timeoutInterval = 24 * 60 * 60
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw RemoteClientError.server("The remote stream could not be opened.")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let value = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard value.utf8.count <= maxPayloadBytes,
                              let payload = value.data(using: .utf8) else {
                            throw RemoteClientError.invalidResponse
                        }
                        continuation.yield(try decode(payload))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func setClipboard(_ text: String) async throws -> RemoteAcceptedResponse {
        try await request("api/clipboard", method: "PUT", body: ["text": text])
    }

    func uploadFile(data: Data, name: String) async throws -> RemoteFileAcceptedResponse {
        var components = URLComponents(url: baseURL.appending(path: "api/files"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components?.url else { throw RemoteClientError.invalidResponse }
        var request = try authorizedRequest(url: url, method: "POST")
        request.timeoutInterval = 60
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        return try decode(RemoteFileAcceptedResponse.self, data: responseData, response: response)
    }

    func downloadFile(named name: String) async throws -> Data {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let request = try authorizedRequest(url: baseURL.appending(path: "api/files/\(encoded)"), method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(RemoteErrorBody.self, from: data).error)
                ?? "Remote request failed (\(http.statusCode))."
            throw RemoteClientError.server(message)
        }
        return data
    }

    func startSession(
        modelID: String,
        message: String,
        autoMode: Bool,
        fullAccess: Bool,
        reasoningEffort: String?,
        botProfileID: String?,
        botComputerID: UUID? = nil,
        workspacePath: String? = nil,
        chatOnly: Bool = false
    ) async throws -> RemoteAcceptedResponse {
        var body: [String: Any] = [
            "modelID": modelID,
            "message": message,
            "autoMode": autoMode,
            "fullAccess": fullAccess,
            "chatOnly": chatOnly,
        ]
        if let reasoningEffort { body["reasoningEffort"] = reasoningEffort }
        if let botProfileID, !botProfileID.isEmpty, botProfileID != "general" {
            body["botProfileID"] = botProfileID
        }
        if let botComputerID { body["botComputerID"] = botComputerID.uuidString }
        if let workspacePath, !workspacePath.isEmpty { body["workspacePath"] = workspacePath }
        return try await request("api/sessions", method: "POST", body: body)
    }

    func session(_ id: UUID) async throws -> RemoteSessionDetail {
        try await request("api/sessions/\(id.uuidString)")
    }

    func send(
        _ message: String,
        to id: UUID,
        autoMode: Bool,
        fullAccess: Bool,
        reasoningEffort: String?,
        modelID: String? = nil,
        action: String? = nil
    ) async throws -> RemoteAcceptedResponse {
        var body: [String: Any] = [
            "message": message,
            "autoMode": autoMode,
            "fullAccess": fullAccess,
        ]
        if let reasoningEffort { body["reasoningEffort"] = reasoningEffort }
        if let modelID, !modelID.isEmpty { body["modelID"] = modelID }
        if let action, !action.isEmpty { body["action"] = action }
        return try await request("api/sessions/\(id.uuidString)/messages", method: "POST", body: body)
    }

    func cancelQueuedTask(_ taskID: UUID, sessionID: UUID) async throws -> RemoteAcceptedResponse {
        try await request(
            "api/sessions/\(sessionID.uuidString)/queue",
            method: "POST",
            body: ["taskID": taskID.uuidString, "action": "cancel"])
    }

    func sessionEvents(_ id: UUID) -> AsyncThrowingStream<RemoteSessionDetail, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try authorizedRequest(
                        url: baseURL.appending(path: "api/sessions/\(id.uuidString)/events"),
                        method: "GET")
                    request.timeoutInterval = 24 * 60 * 60
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw RemoteClientError.server("The live conversation stream could not be opened.")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8) else { continue }
                        continuation.yield(try JSONDecoder().decode(RemoteSessionDetail.self, from: data))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop(_ id: UUID) async throws -> RemoteAcceptedResponse {
        try await request("api/sessions/\(id.uuidString)/stop", method: "POST", body: [:])
    }

    func resolve(_ pending: RemotePendingInteraction, sessionID: UUID, value: String) async throws {
        guard let requestID = pending.requestID else { throw RemoteClientError.invalidResponse }
        let body: [String: Any]
        switch pending.kind {
        case "approval": body = ["requestID": requestID, "approved": value == "approve", "always": false]
        case "question": body = ["requestID": requestID, "answer": value]
        case "plan": body = ["requestID": requestID, "action": value, "feedback": ""]
        default: throw RemoteClientError.invalidResponse
        }
        let _: RemoteAcceptedResponse = try await request(
            "api/sessions/\(sessionID.uuidString)/\(pending.kind)", method: "POST", body: body)
    }

    func revoke() async throws {
        let _: RemoteAcceptedResponse = try await request("api/revoke", method: "POST", body: [:])
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        authorized: Bool = true,
        timeout: TimeInterval = 15
    ) async throws -> Response {
        var request = try authorized
            ? authorizedRequest(url: baseURL.appending(path: path), method: method)
            : URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await Self.apiSession.data(for: request)
            return try decode(Response.self, data: data, response: response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        }
    }

    private func authorizedRequest(url: URL, method: String) throws -> URLRequest {
        guard let token else { throw RemoteClientError.notConnected }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func decode<Response: Decodable>(
        _ type: Response.Type,
        data: Data,
        response: URLResponse
    ) throws -> Response {
        guard let http = response as? HTTPURLResponse else { throw RemoteClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(RemoteErrorBody.self, from: data).error)
                ?? "Remote request failed (\(http.statusCode))."
            throw RemoteClientError.server(message)
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw RemoteClientError.invalidResponse }
    }

    private func headerInt(_ response: HTTPURLResponse, _ name: String) -> Int? {
        headerDouble(response, name).map { Int($0) }
    }

    private func headerDouble(_ response: HTTPURLResponse, _ name: String) -> Double? {
        Double(response.value(forHTTPHeaderField: name) ?? "")
    }
}

enum RemoteTokenStore {
    private static let service = "com.beetcode.remote.ios"
    private static let account = "remote-session-token"
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var loadedAccounts: Set<String> = []

    static func save(_ token: String, computerID: UUID) throws {
        let data = Data(token.utf8)
        let query = query(account: accountName(for: computerID))
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw RemoteClientError.server("The connection token could not be saved securely.")
        }
        let name = accountName(for: computerID)
        cacheLock.lock()
        cache[name] = token
        loadedAccounts.insert(name)
        cacheLock.unlock()
    }

    static func load(computerID: UUID) -> String? {
        load(account: accountName(for: computerID))
    }

    static func clear(computerID: UUID) {
        let name = accountName(for: computerID)
        SecItemDelete(query(account: name) as CFDictionary)
        cacheLock.lock()
        cache[name] = nil
        loadedAccounts.insert(name)
        cacheLock.unlock()
    }

    static func loadLegacy() -> String? { load(account: account) }
    static func clearLegacy() {
        SecItemDelete(query(account: account) as CFDictionary)
        cacheLock.lock()
        cache[account] = nil
        loadedAccounts.insert(account)
        cacheLock.unlock()
    }

    private static func accountName(for id: UUID) -> String { "\(account).\(id.uuidString)" }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load(account: String) -> String? {
        cacheLock.lock()
        if loadedAccounts.contains(account) {
            let value = cache[account]
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            cacheLock.lock()
            loadedAccounts.insert(account)
            cacheLock.unlock()
            return nil
        }
        let value = String(data: data, encoding: .utf8)
        cacheLock.lock()
        if let value { cache[account] = value }
        loadedAccounts.insert(account)
        cacheLock.unlock()
        return value
    }
}
