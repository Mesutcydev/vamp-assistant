import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder (AVCC length-prefixed NALUs) for Mac Control live video.
final class RemoteH264Encoder: @unchecked Sendable {
    struct EncodedFrame: Sendable {
        let data: Data
        let isKeyframe: Bool
        let parameterSets: Data?
        let width: Int
        let height: Int
    }

    typealias OutputHandler = @Sendable (EncodedFrame) -> Void

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var outputHandler: OutputHandler?
    private var width = 0
    private var height = 0
    private var averageBitrate = 8_000_000
    private var expectedFPS = 30
    private var forceNextKeyframe = true
    private var framesSinceKeyframe = 0
    private var busy = false
    private var lastParameterSets: Data?

    /// Drop new frames while an encode is in flight (latest-wins by skipping).
    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }

    func configure(
        width: Int,
        height: Int,
        averageBitrate: Int,
        expectedFPS: Int,
        outputHandler: @escaping OutputHandler
    ) {
        lock.lock()
        defer { lock.unlock() }
        let w = max(width, 2) & ~1
        let h = max(height, 2) & ~1
        let bitrate = max(averageBitrate, 250_000)
        let fps = min(max(expectedFPS, 5), 60)
        let needsRebuild =
            session == nil
            || self.width != w
            || self.height != h
            || self.averageBitrate != bitrate
            || self.expectedFPS != fps
        self.outputHandler = outputHandler
        self.averageBitrate = bitrate
        self.expectedFPS = fps
        guard needsRebuild else { return }
        invalidateLocked()
        self.width = w
        self.height = h
        createSessionLocked()
    }

    func forceKeyframe() {
        lock.lock()
        forceNextKeyframe = true
        lock.unlock()
    }

    /// Returns false when the encoder is busy (caller should drop / keep latest).
    @discardableResult
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> Bool {
        lock.lock()
        guard let session, !busy else {
            lock.unlock()
            return false
        }
        busy = true
        let force = forceNextKeyframe || framesSinceKeyframe >= 15
        forceNextKeyframe = false
        let handler = outputHandler
        let expectedWidth = width
        let expectedHeight = height
        lock.unlock()

        var frameProperties: CFDictionary?
        if force {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }
            guard status == noErr, let sampleBuffer, let handler else { return }
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            ) == noErr,
                  let dataPointer, length > 0 else { return }

            let avcc = Data(bytes: dataPointer, count: length)
            // Prefer the force-keyframe request + NAL scan — sample attachments are often missing.
            let keyframe = force || Self.isKeyframe(sampleBuffer) || Self.avccContainsIDR(avcc)
            var parameterSets: Data?
            if keyframe {
                parameterSets = Self.extractParameterSets(from: sampleBuffer)
                self.lock.lock()
                if let parameterSets {
                    self.lastParameterSets = parameterSets
                } else {
                    parameterSets = self.lastParameterSets
                }
                self.framesSinceKeyframe = 0
                self.lock.unlock()
            } else {
                self.lock.lock()
                self.framesSinceKeyframe += 1
                // Still refresh lastParameterSets from the format when available.
                if self.lastParameterSets == nil {
                    self.lastParameterSets = Self.extractParameterSets(from: sampleBuffer)
                }
                self.lock.unlock()
            }

            handler(EncodedFrame(
                data: avcc,
                isKeyframe: keyframe,
                parameterSets: parameterSets,
                width: expectedWidth,
                height: expectedHeight))
        }

        if status != noErr {
            lock.lock()
            busy = false
            lock.unlock()
            return false
        }
        return true
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        invalidateLocked()
    }

    /// Annex-B SPS/PPS with `00 00 00 01` start codes (H.264 only).
    static func extractParameterSets(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        return annexBParameterSets(from: format)
    }

    static func annexBParameterSets(from format: CMFormatDescription) -> Data? {
        var count = 0
        var nalLength: Int32 = 0
        let probe = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &nalLength)
        guard probe == noErr, count > 0 else { return nil }

        var result = Data()
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size > 0 else { continue }
            result.append(startCode)
            result.append(Data(bytes: pointer, count: size))
        }
        return result.isEmpty ? nil : result
    }

    /// Build Annex-B from raw parameter-set NALUs (no start codes). Used by tests.
    static func annexB(wrappingParameterSets sets: [Data]) -> Data {
        var result = Data()
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        for set in sets where !set.isEmpty {
            result.append(startCode)
            result.append(set)
        }
        return result
    }

    /// Split Annex-B into raw NALUs (without start codes).
    static func splitAnnexB(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        var nalus: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let start = findStartCode(in: data, from: index) else { break }
            let naluStart = start.upperBound
            let next = findStartCode(in: data, from: naluStart)?.lowerBound ?? data.endIndex
            if naluStart < next {
                nalus.append(data.subdata(in: naluStart..<next))
            }
            index = next
        }
        return nalus
    }

    deinit {
        invalidate()
    }

    private static func findStartCode(in data: Data, from: Data.Index) -> Range<Data.Index>? {
        var i = from
        while i + 3 < data.endIndex {
            if data[i] == 0, data[i + 1] == 0 {
                if data[i + 2] == 1 {
                    return i..<(i + 3)
                }
                if data[i + 2] == 0, data[i + 3] == 1 {
                    return i..<(i + 4)
                }
            }
            i = data.index(after: i)
        }
        return nil
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[CFString: Any]],
              let first = attachments.first else { return false }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    static func avccContainsIDR(_ data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { return false }
            let nalType = bytes[offset] & 0x1F
            if nalType == 5 { return true }
            offset += length
        }
        return false
    }

    private func invalidateLocked() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        busy = false
        framesSinceKeyframe = 0
        forceNextKeyframe = true
        lastParameterSets = nil
    }

    private func createSessionLocked() {
        var session: VTCompressionSession?
        // Do not pin imageBufferAttributes to fixed width/height — ScreenCaptureKit
        // surfaces must be accepted as-is (Vamp passes nil here).
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            ] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else { return }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: expectedFPS as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: averageBitrate as CFNumber)
        // Shorter GOP so a phone that missed the first IDR recovers within ~0.5s.
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: max(expectedFPS / 2, 15) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }
}
