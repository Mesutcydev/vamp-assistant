import Foundation

enum AppIdentity {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var userAgent: String {
        "VampCode/\(version) (macOS assistant agent)"
    }

    static var browserUserAgent: String {
        "VampCode/\(version) (agent-controlled browser)"
    }
}
