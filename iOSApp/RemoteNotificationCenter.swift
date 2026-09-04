import Foundation
import UserNotifications
import Observation

extension Notification.Name {
    static let openRemoteSession = Notification.Name("com.beetcode.openRemoteSession")
}

struct RemoteNotificationTarget: Hashable, Sendable {
    let computerID: UUID?
    let sessionID: UUID

    var userInfo: [String: String] {
        var info = ["sessionID": sessionID.uuidString]
        if let computerID { info["computerID"] = computerID.uuidString }
        return info
    }

    init(computerID: UUID?, sessionID: UUID) {
        self.computerID = computerID
        self.sessionID = sessionID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["sessionID"] as? String, let sessionID = UUID(uuidString: raw) else { return nil }
        self.sessionID = sessionID
        computerID = (userInfo["computerID"] as? String).flatMap(UUID.init(uuidString:))
    }
}

@MainActor
@Observable
final class RemoteNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RemoteNotificationCenter()

    var pendingNavigation: RemoteNotificationTarget?

    private var pendingSignatures: [RemoteNotificationTarget: String] = [:]
    private var runningStates: [String: [UUID: Bool]] = [:]

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func observeSessions(_ sessions: [RemoteSessionSummary], computerName: String, computerID: UUID? = nil) {
        let key = computerID?.uuidString ?? "legacy"
        let previous = runningStates[key]
        defer {
            runningStates[key] = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.isRunning) })
        }
        guard let previous else { return }

        for session in sessions {
            guard previous[session.id] == true, !session.isRunning else { continue }
            post(
                id: "session-finished-\(key)-\(session.id.uuidString)",
                title: "Task finished on \(computerName)",
                body: session.title,
                target: RemoteNotificationTarget(computerID: computerID, sessionID: session.id))
        }
    }

    func observeDetail(_ detail: RemoteSessionDetail, computerName: String, computerID: UUID? = nil) {
        let target = RemoteNotificationTarget(computerID: computerID, sessionID: detail.id)
        guard let pending = detail.pending else {
            pendingSignatures.removeValue(forKey: target)
            return
        }
        let signature = "\(pending.kind):\(pending.requestID ?? "")"
        guard pendingSignatures[target] != signature else { return }
        pendingSignatures[target] = signature

        let title: String
        switch pending.kind {
        case "approval": title = "Approval needed on \(computerName)"
        case "question": title = "Question from \(computerName)"
        case "plan": title = "Plan ready on \(computerName)"
        default: title = "Vamp Assistant needs attention"
        }
        post(
            id: "session-attention-\(computerID?.uuidString ?? "legacy")-\(detail.id.uuidString)-\(signature)",
            title: title,
            body: detail.title,
            target: target)
    }

    private func post(id: String, title: String, body: String, target: RemoteNotificationTarget) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = target.userInfo
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let target = RemoteNotificationTarget(userInfo: info) else { return }
        await MainActor.run {
            self.pendingNavigation = target
        }
    }
}
