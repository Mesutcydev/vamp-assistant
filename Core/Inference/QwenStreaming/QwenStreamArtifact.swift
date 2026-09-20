import CryptoKit
import Foundation

/// Only flat, regular files contained in an explicitly authorized directory.
enum QwenStreamPaths {
    static func file(_ name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\\"), !name.contains("\0") else {
            throw QwenStreamSafetensorsError.malformedHeader("unsafe file reference")
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(name)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw QwenStreamSafetensorsError.malformedHeader("symlinked model file")
        }
        guard candidate.resolvingSymlinksInPath().deletingLastPathComponent() == root else {
            throw QwenStreamSafetensorsError.malformedHeader("escaping symlink")
        }
        return candidate
    }
}

enum QwenStreamArtifact {
    static let repo = "mlx-community/Qwen3.5-35B-A3B-4bit"
    static let revision = "1e20fd8d42056f870933bf98ca6211024744f7ec"
    static let modelID = "qwen3.5-35b-a3b-streaming-4bit"
    static let routingK = 8
    static let expertCount = 256
    static let residentBytes: UInt64 = 1_378_869_376
    static let expertBytes: UInt64 = 18_119_393_280
    static let unusedBytes: UInt64 = 893_142_496
    static let expertBundleBytes: UInt64 = 1_769_472
    struct File: Sendable {
        let name: String
        let bytes: Int64
        let sha256: String
        let headerSHA256: String
    }
    static let files: [File] = [
        File(name: "chat_template.jinja", bytes: 7756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715", headerSHA256: ""),
        File(name: "config.json", bytes: 3809, sha256: "c0cf317cba802cfb1d2984d4b4afc98ceb3d86450ed757e028383bfb03643964", headerSHA256: ""),
        File(name: "generation_config.json", bytes: 244, sha256: "4f25002776b741773666203dcea8f54619f177ace3ae483d311102092a4658e0", headerSHA256: ""),
        File(name: "model-00001-of-00004.safetensors", bytes: 5285828971, sha256: "0952c2fd5ec5f6163a045003eb0e60465290ac0ebedbe2cecde35dd95abed345", headerSHA256: "4a3b4420de60057931faff2d91a2e5f1ccf3984105a658e97494f8716f8e8860"),
        File(name: "model-00002-of-00004.safetensors", bytes: 5366101807, sha256: "ddf163fcbaa7fc1ff2e93ee2e3306b1c31c4fe3c7dd46990cd2737d0cc30197f", headerSHA256: "dbff10353518668a03be092a95620dcc215a16b1e23a0796a9a09ad4b4f1ac3c"),
        File(name: "model-00003-of-00004.safetensors", bytes: 5364643286, sha256: "5e7d8deca9240eec828c9a451fbd8a95389a7cc18494f400c330d0717c41f6e1", headerSHA256: "9565bfb20ad126db776bd5ce624b35cb384f8dc06e0be181c5d5572adb0d4417"),
        File(name: "model-00004-of-00004.safetensors", bytes: 4375105375, sha256: "b540bac1ef081d7011e32428e0c2da77f00699db2f4f1508da73ee3b8de40551", headerSHA256: "ff9d432cb779ff356c2ad35e402198f032e75c0aea6656a20f94a1c69c485823"),
        File(name: "model.safetensors.index.json", bytes: 215755, sha256: "56f02123353b7fe444b287a46a779a836cb939860502908da4a79e3b43931cdb", headerSHA256: ""),
        File(name: "tokenizer.json", bytes: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", headerSHA256: ""),
        File(name: "tokenizer_config.json", bytes: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182", headerSHA256: ""),
    ]
    static var downloadBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    static func recognizesConfiguration(_ directory: URL) -> Bool {
        guard let file = files.first(where: { $0.name == "config.json" }),
              let url = try? QwenStreamPaths.file(file.name, in: directory),
              let bytes = try? QwenStreamFileIO.readExactly(at: url, offset: 0, count: Int(file.bytes)) else { return false }
        return digest(bytes) == file.sha256
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Metadata-only admission. Full SHA verification belongs to installation.
    static func inspect(_ directory: URL) throws -> QwenStreamSafetensorsIndex {
        for file in files {
            let url = try QwenStreamPaths.file(file.name, in: directory)
            guard try QwenStreamFileIO.fileSize(at: url) == UInt64(file.bytes) else {
                throw QwenStreamSafetensorsError.malformedHeader("missing or truncated \(file.name)")
            }
            if !file.headerSHA256.isEmpty {
                let prefix = try QwenStreamFileIO.readExactly(at: url, offset: 0, count: 8)
                let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
                guard length <= QwenStreamSafetensorsHeaderParser.maximumHeaderBytes else {
                    throw QwenStreamSafetensorsError.malformedHeader("oversized header")
                }
                let header = try QwenStreamFileIO.readExactly(at: url, offset: 8, count: Int(length))
                guard digest(header) == file.headerSHA256 else {
                    throw QwenStreamSafetensorsError.malformedHeader("unsupported shard geometry")
                }
            } else if file.name == "config.json" || file.name == "model.safetensors.index.json" {
                let bytes = try QwenStreamFileIO.readExactly(at: url, offset: 0, count: Int(file.bytes))
                guard digest(bytes) == file.sha256 else {
                    throw QwenStreamSafetensorsError.malformedHeader("unsupported model configuration/index")
                }
            }
        }
        return try QwenStreamSafetensorsIndex.openSharded(in: directory)
    }

    /// Bounded integrity scan: never maps or buffers a complete shard.
    static func verifyPayloads(_ directory: URL) throws {
        for entry in files where !entry.sha256.isEmpty {
            let file = try QwenStreamPreadFile(path: QwenStreamPaths.file(entry.name, in: directory).path)
            defer { file.close() }
            var hash = SHA256()
            var offset: UInt64 = 0
            while offset < UInt64(entry.bytes) {
                try Task.checkCancellation()
                let count = Int(min(4 * 1024 * 1024, UInt64(entry.bytes) - offset))
                hash.update(data: try file.read(offset: offset, count: count))
                offset += UInt64(count)
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == entry.sha256 else {
                throw QwenStreamSafetensorsError.malformedHeader("checksum mismatch: \(entry.name)")
            }
        }
    }
}
