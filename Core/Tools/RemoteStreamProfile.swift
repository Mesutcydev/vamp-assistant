import Foundation

enum RemoteStreamResolution: String, CaseIterable, Identifiable, Sendable {
    case low = "480p"
    case balanced = "720p"
    case high = "1080p"
    case native

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "480p"
        case .balanced: "720p"
        case .high: "1080p"
        case .native: "Native"
        }
    }

    /// Caps are applied against **pixel** width (Vamp `StreamScaling`), not points.
    var maxWidth: Int? {
        switch self {
        case .low: 854
        case .balanced: 1280
        case .high: 1920
        /// Soft cap so encode stays shippable on 5K/6K panels; still sharper than 1080p.
        case .native: 2560
        }
    }

    /// Approximate Vamp bits-per-pixel bitrate targets for H.264 live encode.
    var averageBitrate: Int {
        switch self {
        case .low: 2_000_000
        case .balanced: 8_000_000
        case .high: 16_000_000
        case .native: 24_000_000
        }
    }

    var framesPerSecond: Int {
        switch self {
        case .low: 24
        case .balanced: 30
        case .high: 30
        case .native: 24
        }
    }

    var refreshIntervalMilliseconds: Int {
        max(1_000 / max(framesPerSecond, 1), 16)
    }

    static func resolve(_ rawValue: String?) -> Self {
        guard let rawValue, let value = Self(rawValue: rawValue.lowercased()) else { return .high }
        return value
    }
}

struct RemoteStreamProfile: Sendable, Equatable {
    let resolution: RemoteStreamResolution
    var maxWidth: Int? { resolution.maxWidth }
    var averageBitrate: Int { resolution.averageBitrate }
    var framesPerSecond: Int { resolution.framesPerSecond }
    var refreshIntervalMilliseconds: Int { resolution.refreshIntervalMilliseconds }

    init(resolution: RemoteStreamResolution = .high) {
        self.resolution = resolution
    }
}
