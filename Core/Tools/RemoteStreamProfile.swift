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
        /// Native matches Vamp's high-resolution allowance (3840) instead of a
        /// bespoke 2560 soft cap, so "Native" on a MacBook-class panel is truly
        /// native instead of a hidden 0.85× downscale.
        case .native: 3840
        }
    }

    /// Ceiling on total pixels, applied with `maxWidth`.
    ///
    /// The long-edge cap alone cannot see a near-square window: 3800×3800 is 14.4 MP and passes
    /// a 3840 edge cap untouched, which is past what the client's decoder is budgeted for. A 4K
    /// UHD frame is the reference envelope — 3840 × 2160 = 8.29 MP — and Vamp's ultra tier stays
    /// inside it.
    var maxPixels: Int? {
        switch self {
        case .low: 854 * 480
        case .balanced: 1280 * 720
        case .high: 1920 * 1080
        case .native: 3840 * 2160
        }
    }

    /// Approximate Vamp bits-per-pixel bitrate targets for H.264 live encode.
    var averageBitrate: Int {
        switch self {
        case .low: 2_000_000
        case .balanced: 8_000_000
        case .high: 16_000_000
        /// Native is the only tier that can reach a 3840×2160 envelope, so it carries the
        /// highest budget the host advertises. Vamp's ultra cap is 48 Mbps.
        case .native: 48_000_000
        }
    }

    var framesPerSecond: Int {
        switch self {
        case .low: 24
        case .balanced: 30
        case .high: 30
        /// Native was 30 fps, which left the sharpest tier the least fluid one. Both ends of
        /// the pair handle 4K60 — the M4 media engine encodes it and the phone decodes it — so
        /// the tier caps at the same 60 Vamp runs quality/ultra at. The bitrate above is scaled
        /// for 60 fps (0.18 bpp at 3840×2160/60) rather than the 0.12 bpp the old 30 fps rate
        /// bought, so raising the rate does not soften the image it was raised for.
        case .native: 60
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
    var maxPixels: Int? { resolution.maxPixels }
    var averageBitrate: Int { resolution.averageBitrate }
    var framesPerSecond: Int { resolution.framesPerSecond }
    var refreshIntervalMilliseconds: Int { resolution.refreshIntervalMilliseconds }

    init(resolution: RemoteStreamResolution = .high) {
        self.resolution = resolution
    }
}
