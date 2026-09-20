import Foundation
import XCTest
@testable import BeetCode

// MARK: - QwenStreamTestSupport
//
// Shared deterministic fixtures for the QwenStream foundation tests. No model
// weights are committed anywhere; every fixture is generated in a temporary
// directory and removed by the test.

enum QwenStreamTestFixtures {
    static func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "QwenStreamTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    // MARK: Safetensors fixtures

    static func writeSafetensors(
        at url: URL,
        tensors: [(name: String, dtype: String, shape: [Int], payload: Data)]
    ) throws {
        var entries: [String: Any] = [:]
        var offset = 0
        var payload = Data()
        for tensor in tensors {
            entries[tensor.name] = [
                "dtype": tensor.dtype,
                "shape": tensor.shape,
                "data_offsets": [offset, offset + tensor.payload.count],
            ]
            payload.append(tensor.payload)
            offset += tensor.payload.count
        }
        let header = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.sortedKeys]
        )
        try writeRaw(at: url, header: header, payload: payload)
    }

    static func writeRawSafetensors(
        at url: URL,
        headerJSON: String,
        payload: Data
    ) throws {
        try writeRaw(at: url, header: Data(headerJSON.utf8), payload: payload)
    }

    static func writeRaw(at url: URL, header: Data, payload: Data) throws {
        var data = Data()
        var length = UInt64(header.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(header)
        data.append(payload)
        try data.write(to: url)
    }

    static func payload(shape: [Int], dtype: QwenStreamSafetensorsDType) -> Data {
        let count = shape.reduce(1, *) * dtype.byteWidth
        return Data((0..<count).map { UInt8($0 % 251) })
    }

    static func zeroPayload(shape: [Int], dtype: QwenStreamSafetensorsDType) -> Data {
        Data(count: shape.reduce(1, *) * dtype.byteWidth)
    }

}
