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

    func startSession(modelID: String, message: String) async throws -> RemoteAcceptedResponse {
        try await request("api/sessions", method: "POST", body: ["modelID": modelID, "message": message])
    }

    func session(_ id: UUID) async throws -> RemoteSessionDetail {
        try await request("api/sessions/\(id.uuidString)")
    }

    func send(_ message: String, to id: UUID) async throws -> RemoteAcceptedResponse {
        try await request("api/sessions/\(id.uuidString)/messages", method: "POST", body: ["message": message])
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
        authorized: Bool = true
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if authorized {
            guard let token else { throw RemoteClientError.notConnected }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
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

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw RemoteClientError.server("The connection token could not be saved securely.")
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
