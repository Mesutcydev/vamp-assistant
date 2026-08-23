import Foundation
import Security

struct RemoteAPIClient {
    let baseURL: URL
    var token: String?

    func pair(code: String) async throws -> RemotePairResponse {
        try await request("api/pair", method: "POST", body: ["code": code], authorized: false)
    }

    func status() async throws -> RemoteStatus { try await request("api/status") }
    func sessions() async throws -> RemoteSessionEnvelope { try await request("api/sessions") }
    func models() async throws -> RemoteModelEnvelope { try await request("api/models") }
    func saveAPIKey(providerID: String, key: String) async throws -> RemoteAcceptedResponse {
        try await request("api/providers/key", method: "POST", body: ["providerID": providerID, "key": key], timeout: 30)
    }
    func botComputers() async throws -> RemoteBotComputerEnvelope { try await request("api/bot-computers") }
    func refreshBotComputers() async throws -> RemoteBotComputerEnvelope { try await request("api/bot-computers/refresh", method: "POST", body: [:]) }
    func startBotComputer(_ id: UUID) async throws -> RemoteAcceptedResponse { try await request("api/bot-computers/\(id.uuidString)/start", method: "POST", body: [:]) }
    func stopBotComputer(_ id: UUID) async throws -> RemoteAcceptedResponse { try await request("api/bot-computers/\(id.uuidString)/stop", method: "POST", body: [:]) }
    func clipboard() async throws -> RemoteClipboardSnapshot { try await request("api/clipboard") }
    func sharedFiles() async throws -> RemoteSharedFileEnvelope { try await request("api/files") }

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
        botComputerID: UUID? = nil
    ) async throws -> RemoteAcceptedResponse {
        var body: [String: Any] = [
            "modelID": modelID,
            "message": message,
            "autoMode": autoMode,
            "fullAccess": fullAccess,
        ]
        if let reasoningEffort { body["reasoningEffort"] = reasoningEffort }
        if let botProfileID, !botProfileID.isEmpty, botProfileID != "general" {
            body["botProfileID"] = botProfileID
        }
        if let botComputerID { body["botComputerID"] = botComputerID.uuidString }
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
        modelID: String? = nil
    ) async throws -> RemoteAcceptedResponse {
        var body: [String: Any] = [
            "message": message,
            "autoMode": autoMode,
            "fullAccess": fullAccess,
        ]
        if let reasoningEffort { body["reasoningEffort"] = reasoningEffort }
        if let modelID, !modelID.isEmpty { body["modelID"] = modelID }
        return try await request("api/sessions/\(id.uuidString)/messages", method: "POST", body: body)
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
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(Response.self, data: data, response: response)
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
}

enum RemoteTokenStore {
    private static let service = "com.beetcode.remote.ios"
    private static let account = "remote-session-token"

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
    }

    static func load(computerID: UUID) -> String? {
        load(account: accountName(for: computerID))
    }

    static func clear(computerID: UUID) {
        SecItemDelete(query(account: accountName(for: computerID)) as CFDictionary)
    }

    static func loadLegacy() -> String? { load(account: account) }
    static func clearLegacy() { SecItemDelete(query(account: account) as CFDictionary) }

    private static func accountName(for id: UUID) -> String { "\(account).\(id.uuidString)" }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load(account: String) -> String? {
        var lookup = query(account: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
