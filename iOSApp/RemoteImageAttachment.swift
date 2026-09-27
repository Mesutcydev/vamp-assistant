import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A normalized image draft. JPEG conversion handles HEIC and orientation;
/// limiting dimensions also keeps phone uploads and projector memory bounded.
struct RemoteImageAttachment: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let data: Data
    static let maximumCount = 4
    static let maximumBytes = 2 * 1024 * 1024

    var requestValue: [String: String] { ["base64": data.base64EncodedString()] }

    enum ImportError: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: "This file couldn’t be opened as an image. Choose a photo or screenshot."
            case .tooLarge: "This image is too large. Choose a smaller photo or screenshot."
            }
        }
    }

    static func prepare(_ original: Data) throws -> Self {
        guard !original.isEmpty, original.count <= 50 * 1024 * 1024 else { throw ImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw ImportError.invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ImportError.invalid }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImportError.invalid }
        let data = output as Data
        guard data.count <= maximumBytes else { throw ImportError.tooLarge }
        return Self(id: UUID(), data: data)
    }
}
