import Foundation
import MLX
import XCTest

/// Selector-only Q2.8 diagnostic. The raw fixture is produced by the
/// independent Python Metal oracle and one native streamed run; this test
/// never loads the checkpoint or changes production routing.
final class QwenStreamQ28TieTests: XCTestCase {
    private struct RawArray: Decodable {
        let shape: [Int]
        let dtype: String
        let values: [Float]?
        let fullValues: [Float]?
        let rawBFloat16Bits: [UInt16]?
        let rawUInt16Bits: [UInt16]?
        let rawUInt32Bits: [UInt32]?
    }

    private struct RawSide: Decodable {
        let routerInput: RawArray
        let routerLogits: RawArray
        let selectorScores: RawArray
        let selectedExpertIDs: [Int]
        let selectedNormalizedScores: [Float]
    }

    private struct RawFixture: Decodable {
        let fixtureFormatVersion: String
        struct Artifact: Decodable {
            let repo: String
            let revision: String
            let inventorySHA256: String
            let bytes: Int?
        }
        let artifact: Artifact?
        let layer: Int
        let position: Int
        let routingK: Int
        let reference: RawSide
        let native: RawSide
    }

    func testOptInQ28CutoffTieSelectorReplay() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BEETCODE_QWEN35_Q28_RAW_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("Set BEETCODE_QWEN35_Q28_RAW_FIXTURE to the compact raw cutoff fixture.")
        }
        let fixture = try JSONDecoder().decode(RawFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(fixture.fixtureFormatVersion, "qwen35-k8-cutoff-tie-v1")
        XCTAssertEqual(fixture.artifact?.repo, "mlx-community/Qwen3.5-35B-A3B-4bit")
        XCTAssertEqual(fixture.artifact?.revision, "1e20fd8d42056f870933bf98ca6211024744f7ec")
        XCTAssertEqual(fixture.artifact?.inventorySHA256, "0fdb73d3e1bc7818442eb03edb0d2926858891e48c8f5eff5c285c50d9bff592")
        XCTAssertEqual(fixture.artifact?.bytes, 20_411_897_485)
        XCTAssertEqual(fixture.routingK, 8)
        XCTAssertEqual(fixture.layer, 19)
        XCTAssertEqual(fixture.position, 46)

        for (label, side) in [("reference", fixture.reference), ("native", fixture.native)] {
            let selector = try makeArray(side.selectorScores)
            let values = selector.asType(.float32).flattened().asArray(Float.self)
            XCTAssertEqual(values.count, 256, "(label) selector width")
            let cutoff = values.sorted(by: >)[fixture.routingK - 1]
            let greater = values.indices.filter { values[$0] > cutoff }
            let equal = values.indices.filter { values[$0] == cutoff }
            let less = values.indices.filter { values[$0] < cutoff }
            let replaySets = (0..<16).map { _ in replay(selector, k: fixture.routingK) }
            let firstSet = Set(replaySets[0])
            let uniqueOrders = Set(replaySets.map { $0.map(String.init).joined(separator: ",") }).count
            XCTAssertTrue(replaySets.allSatisfy { Set($0) == firstSet }, "(label) selector set changed across replays")
            XCTAssertEqual(firstSet, Set(side.selectedExpertIDs), "(label) replay did not reproduce the captured argpartition set")
            XCTAssertTrue(greater.allSatisfy { firstSet.contains($0) }, "(label) a strictly-greater expert was omitted")
            XCTAssertTrue(firstSet.subtracting(greater).allSatisfy { equal.contains($0) }, "(label) a below-cutoff expert was selected")
            print("[qwen-q28-selector] side=\(label) dtype=\(side.selectorScores.dtype) cutoff=\(cutoff) greater=\(greater) equal=\(equal) lessCount=\(less.count) replayUniqueOrders=\(uniqueOrders) replaySet=\(replaySets[0])")

            let score61 = values[61]
            let score245 = values[245]
            let raw61 = rawWord(side.selectorScores, index: 61)
            let raw245 = rawWord(side.selectorScores, index: 245)
            if label == "reference" {
                XCTAssertNotEqual(raw61, raw245, "reference candidates must remain non-tied at selector precision")
            } else {
                XCTAssertEqual(raw61, raw245, "native diagnostic should retain the exact cutoff tie")
            }
            print("[qwen-q28-cutoff] side=\(label) score61=\(score61) score245=\(score245) difference=\(score61 - score245) raw61=\(raw61) raw245=\(raw245)")
        }
    }

    private func replay(_ values: MLXArray, k: Int) -> [Int] {
        let width = values.dim(-1)
        let kth = width - k
        let partition = MLX.argPartition(values, kth: kth, axis: -1)
        MLX.eval(partition)
        return Array(partition.asArray(Int.self)[kth...])
    }

    private func makeArray(_ summary: RawArray) throws -> MLXArray {
        if let bits = summary.rawUInt16Bits ?? summary.rawBFloat16Bits {
            let data = bits.withUnsafeBytes { Data($0) }
            let raw = MLXArray(data, summary.shape, dtype: .uint16)
            let lower = summary.dtype.lowercased()
            guard lower.contains("bfloat16") || lower.contains("float16") else {
                throw NSError(domain: "QwenQ28", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported 16-bit selector dtype (summary.dtype)"])
            }
            return raw.view(dtype: lower.contains("bfloat16") ? .bfloat16 : .float16)
        }
        if let bits = summary.rawUInt32Bits {
            let data = bits.withUnsafeBytes { Data($0) }
            return MLXArray(data, summary.shape, dtype: .uint32).view(dtype: .float32)
        }
        guard let values = summary.fullValues ?? summary.values else {
            throw NSError(domain: "QwenQ28", code: 2, userInfo: [NSLocalizedDescriptionKey: "raw selector bits are missing"])
        }
        let data = values.withUnsafeBytes { Data($0) }
        return MLXArray(data, summary.shape, dtype: .float32)
    }

    private func rawWord(_ summary: RawArray, index: Int) -> String {
        if let bits = summary.rawUInt16Bits ?? summary.rawBFloat16Bits, bits.indices.contains(index) {
            return String(format: "0x%04X", bits[index])
        }
        if let bits = summary.rawUInt32Bits, bits.indices.contains(index) {
            return String(format: "0x%08X", bits[index])
        }
        return "unavailable"
    }
}
