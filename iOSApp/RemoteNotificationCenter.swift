import Foundation
import UserNotifications

@MainActor
final class RemoteNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RemoteNotificationCenter()

    private var pendingSignatures: [UUID: String] = [:]
    private var runningStates: [UUID: Bool] = [:]
    private var hasSeededSessions = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func observeSessions(_ sessions: [RemoteSessionSummary], computerName: String) {
        defer {
            runningStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.isRunning) })
            hasSeededSessions = true
        }
        guard hasSeededSessions else { return }

        for session in sessions {
            guard runningStates[session.id] == true, !session.isRunning else { continue }
            post(
                id: "session-finished-\(session.id.uuidString)",
                title: "Task finished on \(computerName)",
                body: session.title,
                sessionID: session.id)
        }
    }

    func observeDetail(_ detail: RemoteSessionDetail, computerName: String) {
        guard let pending = detail.pending else {
            pendingSignatures.removeValue(forKey: detail.id)
            return
        }
        let signature = "\(pending.kind):\(pending.requestID ?? "")"
        guard pendingSignatures[detail.id] != signature else { return }
        pendingSignatures[detail.id] = signature

        let title: String
        switch pending.kind {
        case "approval": title = "Approval needed on \(computerName)"
        case "question": title = "Question from \(computerName)"
        case "plan": title = "Plan ready on \(computerName)"
        default: title = "BeetCode needs attention"
        }
        post(
            id: "session-attention-\(detail.id.uuidString)-\(signature)",
            title: title,
            body: detail.title,
            sessionID: detail.id)
    }

    private func post(id: String, title: String, body: String, sessionID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
