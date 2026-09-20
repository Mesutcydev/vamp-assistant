import XCTest
@testable import BeetCode

final class QwenStreamReferenceAuditTests: XCTestCase {
    func testRealArtifactQuantizedProjectionMatchesDenseReference() throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_QWEN35_PARITY"] == "1" else {
            throw XCTSkip("Set BEETCODE_QWEN35_PARITY=1 to run the bounded real-artifact audit.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home
            .appendingPathComponent("Library/Application Support/BeetCode/Models", isDirectory: true)
            .appendingPathComponent(QwenStreamArtifact.modelID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Pinned Qwen3.5-35B-A3B artifact is not installed.")
        }

        let report = try QwenStreamReferenceAudit.run(directory: directory)
        XCTAssertEqual(report.artifactRevision, QwenStreamArtifact.revision)
        XCTAssertEqual(report.projections.count, 3)
        for projection in report.projections {
            print("[qwen-reference] layer=\(projection.layer) expert=\(projection.expert) projection=\(projection.projection) shape=\(projection.shape) relL2=\(projection.relL2) maxAbs=\(projection.maxAbs) finite=\(projection.tokenSafe)")
            XCTAssertTrue(projection.tokenSafe, projection.projection)
            // The dense path dequantizes to float32 while the quantized Metal
            // kernel accumulates in its native precision. Freeze the observed
            // artifact-level tolerance before using it as a parity oracle.
            XCTAssertLessThan(
                projection.relL2, 0.01,
                "\(projection.projection) relL2=\(projection.relL2) maxAbs=\(projection.maxAbs)"
            )
            XCTAssertLessThan(
                projection.maxAbs, 0.25,
                "\(projection.projection) relL2=\(projection.relL2) maxAbs=\(projection.maxAbs)"
            )
        }
    }
}
