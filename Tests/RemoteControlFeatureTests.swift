import Foundation
import XCTest
@testable import BeetCode

final class RemoteControlFeatureTests: XCTestCase {
    func testInputBufferCoalescesContinuousCommandsButKeepsBarriers() {
        var buffer = RemoteInputCommandBuffer()

        XCTAssertFalse(buffer.append(.relative(dx: 2, dy: 3)))
        XCTAssertTrue(buffer.append(.relative(dx: 4, dy: -1)))
        XCTAssertFalse(buffer.append(.down(button: "left")))
        XCTAssertFalse(buffer.append(.move(x: 100, y: 200)))
        XCTAssertTrue(buffer.append(.move(x: 110, y: 220)))
        XCTAssertFalse(buffer.append(.up(button: "left")))

        XCTAssertEqual(
            buffer.commands,
            [
                .relative(dx: 6, dy: 2),
                .down(button: "left"),
                .move(x: 110, y: 220),
                .up(button: "left")
            ]
        )
    }

    func testInputBufferAggregatesScrollOnlyUntilTheNextBarrier() {
        var buffer = RemoteInputCommandBuffer()
        XCTAssertFalse(buffer.append(.scroll(x: nil, y: nil, dx: 2.25, dy: 5.5)))
        XCTAssertTrue(buffer.append(.scroll(x: 10, y: 20, dx: -1.25, dy: 3.25)))
        XCTAssertFalse(buffer.append(.key("return", modifiers: [])))

        XCTAssertEqual(
            buffer.commands,
            [
                .scroll(x: 10, y: 20, dx: 1, dy: 8.75),
                .key("return", modifiers: [])
            ]
        )
    }

    func testInputBufferDrainsWithoutReorderingAndTrimsMotionOnly() {
        var buffer = RemoteInputCommandBuffer()
        for index in 0..<100 {
            _ = buffer.append(.relative(dx: Double(index), dy: 1))
        }
        _ = buffer.append(.down(button: "left"))
        _ = buffer.append(.up(button: "left"))
        buffer.trimMotion(keeping: 4)

        XCTAssertEqual(buffer.commands.last, .up(button: "left"))
        XCTAssertTrue(buffer.commands.contains(.down(button: "left")))
        XCTAssertLessThanOrEqual(buffer.commands.count, 4)
        XCTAssertEqual(buffer.drain(maxCount: 1).count, 1)
    }

    func testPointerCurveIsBoundedAndFasterMotionHasMoreGain() {
        var slow = RemotePointerCurve()
        var fast = RemotePointerCurve()
        let slowOutput = slow.apply(dx: 1, dy: 0, elapsed: 0.1)
        let fastOutput = fast.apply(dx: 10, dy: 0, elapsed: 0.005)

        XCTAssertGreaterThan(fastOutput.dx / 10, slowOutput.dx)
        XCTAssertGreaterThanOrEqual(slowOutput.dx, 1.0)
        XCTAssertLessThanOrEqual(fastOutput.dx / 10, 2.5)
        XCTAssertEqual(slowOutput.dy, 0, accuracy: 0.0001)
    }

    func testPointerCurveRejectsNonFiniteInputAndResetsVelocity() {
        var curve = RemotePointerCurve()
        XCTAssertEqual(curve.apply(dx: .infinity, dy: 1, elapsed: 0.01).dx, 0)
        _ = curve.apply(dx: 20, dy: 0, elapsed: 0.01)
        XCTAssertGreaterThan(curve.filteredVelocity, 0)
        curve.reset()
        XCTAssertEqual(curve.filteredVelocity, 0)
    }

    func testStreamResolutionProfilesAreSelectableAndBounded() {
        XCTAssertEqual(RemoteStreamResolution.resolve("1080P"), .high)
        XCTAssertEqual(RemoteStreamResolution.resolve("unknown"), .high)
        XCTAssertEqual(RemoteStreamResolution.native.maxWidth, 2560)
        XCTAssertEqual(RemoteStreamResolution.low.averageBitrate, 2_000_000)
        XCTAssertEqual(RemoteStreamResolution.balanced.averageBitrate, 8_000_000)
        XCTAssertEqual(RemoteStreamResolution.high.averageBitrate, 16_000_000)
        XCTAssertEqual(RemoteStreamResolution.native.averageBitrate, 24_000_000)
        XCTAssertLessThan(RemoteStreamResolution.low.averageBitrate, RemoteStreamResolution.high.averageBitrate)
        XCTAssertEqual(RemoteStreamResolution.balanced.framesPerSecond, 30)
        XCTAssertEqual(RemoteStreamResolution.low.framesPerSecond, 24)
        XCTAssertEqual(RemoteStreamResolution.native.framesPerSecond, 24)
        XCTAssertLessThanOrEqual(RemoteStreamResolution.balanced.refreshIntervalMilliseconds, 50)
    }

    func testAnnexBParameterSetRoundTrip() {
        let sps = Data([0x67, 0x64, 0x00, 0x1f, 0xac, 0xd9])
        let pps = Data([0x68, 0xee, 0x3c, 0xb0])
        let annexB = RemoteH264Encoder.annexB(wrappingParameterSets: [sps, pps])
        XCTAssertEqual(Array(annexB.prefix(4)), [0, 0, 0, 1])
        let split = RemoteH264Encoder.splitAnnexB(annexB)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0], sps)
        XCTAssertEqual(split[1], pps)
        XCTAssertGreaterThanOrEqual(RemoteStreamResolution.low.averageBitrate, 1_000_000)
        XCTAssertLessThanOrEqual(RemoteStreamResolution.native.averageBitrate, 40_000_000)
    }

    func testDisplayMappingFitsAndFillsWithoutStretchingClicks() {
        let view = CGSize(width: 400, height: 800)
        let image = CGSize(width: 1920, height: 1080)
        let fit = RemoteDisplayMapping.contentRect(imageSize: image, in: view, mode: .fit)
        let fill = RemoteDisplayMapping.contentRect(imageSize: image, in: view, mode: .fill)

        XCTAssertEqual(fit.width, 400, accuracy: 0.1)
        XCTAssertLessThan(fit.height, 800)
        XCTAssertEqual(fill.height, 800, accuracy: 0.1)
        XCTAssertGreaterThan(fill.width, 400)

        let center = CGPoint(x: fit.midX, y: fit.midY)
        let mapped = RemoteDisplayMapping.mapPoint(
            center,
            contentRect: fit,
            displayX: 100,
            displayY: 200,
            displayWidth: 1920,
            displayHeight: 1080)
        XCTAssertEqual(mapped?.x ?? 0, 100 + 960, accuracy: 1)
        XCTAssertEqual(mapped?.y ?? 0, 200 + 540, accuracy: 1)
        XCTAssertNil(RemoteDisplayMapping.mapPoint(
            CGPoint(x: 10, y: 10),
            contentRect: fit,
            displayX: 0,
            displayY: 0,
            displayWidth: 1920,
            displayHeight: 1080))
        // Letterbox tap above content rides the top edge (y→0), keeping view x.
        let edge = RemoteDisplayMapping.mapPoint(
            CGPoint(x: 10, y: 10),
            contentRect: fit,
            displayX: 0,
            displayY: 0,
            displayWidth: 1920,
            displayHeight: 1080,
            clampToContent: true)
        XCTAssertEqual(edge?.x ?? -1, 10.0 / fit.width * 1920, accuracy: 1)
        XCTAssertEqual(edge?.y ?? -1, 0, accuracy: 1)
    }

    func testRelativeDeltaScalesWithDisplaySize() {
        let scaled = RemoteDisplayMapping.scaleRelativeDelta(
            dx: 10,
            dy: 5,
            displayWidth: 1920,
            displayHeight: 1080,
            surfaceWidth: 320,
            surfaceHeight: 200,
            sensitivity: 2.0)
        XCTAssertGreaterThan(scaled.dx, 10)
        XCTAssertGreaterThan(scaled.dy, 5)
    }

    func testScrollAndAccelerationMatchVampCurves() {
        let scroll = RemoteDisplayMapping.scaleViewDeltaToDisplay(
            dx: 10,
            dy: -20,
            contentWidth: 320,
            contentHeight: 200,
            displayWidth: 1920,
            displayHeight: 1080)
        XCTAssertEqual(scroll.dx, 10 * (1920 / 320), accuracy: 0.01)
        XCTAssertEqual(scroll.dy, -20 * (1080 / 200), accuracy: 0.01)

        let slow = RemoteDisplayMapping.accelerated(dx: 1, dy: 0)
        let fast = RemoteDisplayMapping.accelerated(dx: 40, dy: 0)
        XCTAssertGreaterThan(fast.dx / 40, slow.dx)
        XCTAssertLessThanOrEqual(fast.dx / 40, 2.5 + 0.01)
    }

    func testControlBodyEncodesFractionalScrollAndRelativeMotion() {
        XCTAssertEqual(RemoteInputCommand.relative(dx: 1.25, dy: -0.5).wireBody()["action"] as? String, "rel")
        XCTAssertEqual(RemoteInputCommand.scroll(x: nil, y: nil, dx: 0.25, dy: -1.5).wireBody()["dx"] as? Double, 0.25)
        XCTAssertEqual(RemoteInputCommand.scroll(x: nil, y: nil, dx: 0.25, dy: -1.5).wireBody()["dy"] as? Double, -1.5)
    }

    func testAudioChunkPayloadDecodesPCM() throws {
        let payload = try JSONDecoder().decode(
            RemoteMacAudioPayload.self,
            from: Data("{\"sr\":48000,\"ch\":2,\"pcm\":\"AQIDBA==\"}".utf8)
        )
        XCTAssertEqual(payload.sampleRate, 48_000)
        XCTAssertEqual(payload.channelCount, 2)
        XCTAssertEqual(payload.pcmData, Data([1, 2, 3, 4]))
    }

    func testTerminalPayloadPrefersRawBytesAndSupportsLegacyText() throws {
        let raw = try JSONDecoder().decode(
            TestTerminalOutputPayload.self,
            from: Data("{\"data\":\"AP8=\",\"out\":\"ignored\"}".utf8)
        )
        XCTAssertEqual(raw.bytes, Data([0, 255]))

        let legacy = try JSONDecoder().decode(
            TestTerminalOutputPayload.self,
            from: Data("{\"out\":\"prompt> \"}".utf8)
        )
        XCTAssertEqual(legacy.bytes, Data("prompt> ".utf8))
    }
}

private struct TestTerminalOutputPayload: Decodable {
    let data: Data?
    let output: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case output = "out"
    }

    var bytes: Data? {
        data ?? output.map { Data($0.utf8) }
    }
}

struct RemoteMacAudioPayload: Decodable {
    let sampleRate: Double
    let channelCount: Int
    let pcmData: Data

    private enum CodingKeys: String, CodingKey {
        case sampleRate = "sr"
        case channelCount = "ch"
        case pcm = "pcm"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        channelCount = try container.decode(Int.self, forKey: .channelCount)
        let encoded = try container.decode(String.self, forKey: .pcm)
        guard let data = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(forKey: .pcm, in: container, debugDescription: "Invalid PCM")
        }
        pcmData = data
    }
}
