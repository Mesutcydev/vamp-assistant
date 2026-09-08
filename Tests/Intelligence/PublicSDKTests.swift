import Foundation
import XCTest
@testable import BeetCode

/// Phase 22 — SDK facade + CLI routing against a real workspace.
final class PublicSDKTests: XCTestCase {

    private var retained: [TempWorkspace] = []
    private var workspace: TempWorkspace!

    override func setUp() async throws {
        let ws = TempWorkspace()
        retained.append(ws)
        workspace = ws
        ws.write("""
        final class AuthService {
            func refreshToken() {
                persistSession()
            }

            private func persistSession() {
            }
        }
        """, to: "Sources/Auth/AuthService.swift")
        ws.write("""
        final class SessionManager {
            func resume() {
                AuthService().refreshToken()
            }
        }
        """, to: "Sources/Auth/SessionManager.swift")

        let storeDir = TempWorkspace()
        retained.append(storeDir)
        IntelligenceStoreLayout.overrideRoot = storeDir.url
        WorkspaceSnapshotStore.shared.overrideDirectory =
            storeDir.url.appendingPathComponent("snapshots")
    }

    // MARK: SDK facade

    func testFacadeEndToEnd() async throws {
        let intel = WorkspaceIntelligence(workspaceRoot: workspace.url)

        let stats = try await intel.index()
        XCTAssertEqual(stats.parsed, 2)

        let overview = try intel.overview()
        XCTAssertTrue(overview.contains("swift"), overview)

        let packet = try intel.context(for: "how does refreshToken work")
        XCTAssertTrue(packet.symbols.contains { $0.name == "refreshToken" })

        let hits = try intel.searchSymbols(matching: "session")
        XCTAssertTrue(hits.contains { $0.name == "SessionManager" })
    }
}
