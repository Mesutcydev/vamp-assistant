import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Thread-safe H.264 (AVCC) decoder for Mac Control live video.
final class RemoteH264Decoder: @unchecked Sendable {
    typealias PixelHandler = @Sendable (SendablePixelBuffer) -> Void
    typealias EventHandler = @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "beet.remote.h264.decode", qos: .userInteractive)
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var lastParameterSets: Data?
    private var outputHandler: PixelHandler?
    private var eventHandler: EventHandler?
    private var requestedKeyframe = false
    private struct PendingFrame {
        let data: Data
        let keyframe: Bool
        let parameterSets: Data?

        var isRecoveryPoint: Bool {
            keyframe || parameterSets?.isEmpty == false || RemoteH264Decoder.avccContainsIDR(data)
        }
    }
    /// Video is live, so stale frames are less useful than the newest one.
    /// Keep a recovery frame plus the latest delta instead of allowing the
    /// serial decode queue to grow without bound during a burst.
    private var pendingFrames: [PendingFrame] = []
    private var drainScheduled = false
    private var resetPending = false

    func setOutputHandler(_ handler: @escaping PixelHandler) {
        lock.lock()
        outputHandler = handler
        lock.unlock()
    }

    func setEventHandler(_ handler: @escaping EventHandler) {
        lock.lock()
        eventHandler = handler
        lock.unlock()
    }

    func reset() {
        lock.lock()
        pendingFrames.removeAll(keepingCapacity: true)
        resetPending = true
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.tearDownSession()
            self.lock.lock()
            self.lastParameterSets = nil
            self.requestedKeyframe = false
            self.resetPending = false
            let shouldDrain = !self.pendingFrames.isEmpty && !self.drainScheduled
            if shouldDrain { self.drainScheduled = true }
            self.lock.unlock()
            self.emit("decoder reset")
            if shouldDrain { self.drainPendingFrames() }
        }
    }

    func decode(data: Data, keyframe: Bool, parameterSets: Data?) {
        let frame = PendingFrame(data: data, keyframe: keyframe, parameterSets: parameterSets)
        lock.lock()
        enqueueBounded(frame)
        let shouldSchedule = !drainScheduled && !resetPending
        if shouldSchedule { drainScheduled = true }
        lock.unlock()
        guard shouldSchedule else { return }
        queue.async { [weak self] in
            self?.drainPendingFrames()
        }
    }

    /// Called with `lock` held. The queue never exceeds two waiting frames.
    private func enqueueBounded(_ frame: PendingFrame) {
        if frame.isRecoveryPoint {
            pendingFrames = [frame]
            return
        }
        if pendingFrames.count < 2 {
            pendingFrames.append(frame)
            return
        }
        if let recovery = pendingFrames.first(where: \.isRecoveryPoint) {
            pendingFrames = [recovery, frame]
        } else {
            pendingFrames = [frame]
        }
    }

    private func drainPendingFrames() {
        while true {
            lock.lock()
            if resetPending || pendingFrames.isEmpty {
                drainScheduled = false
                lock.unlock()
                return
            }
            let frame = pendingFrames.removeFirst()
            lock.unlock()
            decodeOnQueue(
                data: frame.data,
                keyframe: frame.keyframe,
                parameterSets: frame.parameterSets)
        }
    }

    private func decodeOnQueue(data: Data, keyframe: Bool, parameterSets: Data?) {
        let idr = keyframe || Self.avccContainsIDR(data)
        // Apply SPS/PPS whenever present — don't wait for a possibly-misflagged keyframe bit.
        if let parameterSets, !parameterSets.isEmpty {
            let changed: Bool = {
                lock.lock()
                defer { lock.unlock() }
                let changed = lastParameterSets != parameterSets
                lastParameterSets = parameterSets
                return changed
            }()
            if changed || session == nil {
                if rebuildSession(parameterSets: parameterSets) {
                    emit("VT session ready (\(parameterSets.count)B params)")
                } else {
                    emit("VT session rebuild failed")
                    requestKeyframe("params rebuild failed")
                    return
                }
            }
        }

        guard session != nil, formatDescription != nil else {
            requestKeyframe("no session yet")
            return
        }

        if idr {
            lock.lock()
            requestedKeyframe = false
            lock.unlock()
        }

        guard let sampleBuffer = makeSampleBuffer(avcc: data, keyframe: idr) else {
            // makeSampleBuffer already emitted a specific status breadcrumb.
            if idr { requestKeyframe("sample create failed") }
            return
        }

        // Synchronous decode for live desktop — avoids dropped first-frame callbacks.
        var flagsOut: VTDecodeInfoFlags = []
        let status = VTDecompressionSessionDecodeFrame(
            session!,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &flagsOut
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                if status != noErr {
                    self.emit("VT decode cb status=\(status)")
                    self.requestKeyframe("decode status \(status)")
                }
                return
            }
            let handler: PixelHandler? = {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.outputHandler
            }()
            handler?(SendablePixelBuffer(buffer: imageBuffer))
        }

        if status != noErr {
            emit("VTDecodeFrame status=\(status)")
            requestKeyframe("VTDecodeFrame \(status)")
        }
    }

    private func requestKeyframe(_ reason: String) {
        let shouldNotify: Bool = {
            lock.lock()
            defer { lock.unlock() }
            guard !requestedKeyframe else { return false }
            requestedKeyframe = true
            return true
        }()
        guard shouldNotify else { return }
        emit("need keyframe: \(reason)")
    }

    private func emit(_ message: String) {
        let handler: EventHandler? = {
            lock.lock()
            defer { lock.unlock() }
            return eventHandler
        }()
        handler?(message)
    }

    private func rebuildSession(parameterSets: Data) -> Bool {
        tearDownSession()
        let nalus = Self.splitAnnexB(parameterSets)
        guard nalus.count >= 2 else {
            emit("params need ≥2 NALUs, got \(nalus.count)")
            return false
        }

        var flat: [UInt8] = []
        var offsets: [Int] = []
        var sizes: [Int] = []
        flat.reserveCapacity(parameterSets.count)
        for nalu in nalus {
            offsets.append(flat.count)
            sizes.append(nalu.count)
            flat.append(contentsOf: nalu)
        }

        var format: CMVideoFormatDescription?
        let createStatus = flat.withUnsafeBufferPointer { flatBP -> OSStatus in
            guard let base = flatBP.baseAddress else { return -1 }
            let ptrs: [UnsafePointer<UInt8>] = offsets.map { base + $0 }
            return ptrs.withUnsafeBufferPointer { ptrBP in
                sizes.withUnsafeBufferPointer { sizeBP in
                    guard let pp = ptrBP.baseAddress, let sp = sizeBP.baseAddress else { return -1 }
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: nalus.count,
                        parameterSetPointers: pp,
                        parameterSetSizes: sp,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &format)
                }
            }
        }
        guard createStatus == noErr, let format else {
            emit("CreateFromH264ParameterSets status=\(createStatus)")
            return false
        }

        var session: VTDecompressionSession?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session)
        guard status == noErr, let session else {
            emit("VTDecompressionSessionCreate status=\(status)")
            return false
        }

        self.formatDescription = format
        self.session = session
        return true
    }

    private func makeSampleBuffer(avcc: Data, keyframe: Bool) -> CMSampleBuffer? {
        guard let formatDescription, !avcc.isEmpty else { return nil }

        // Match Vamp: allocate with dataLength == byte count, then copy into
        // block-owned memory. dataLength:0 + ReplaceDataBytes fails on iOS
        // (destination range is empty), which produced "CMSampleBuffer create failed".
        var block: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block)
        guard createStatus == noErr, let block else {
            emit("CMBlockBuffer create status=\(createStatus)")
            return nil
        }

        let replaceStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count)
        }
        guard replaceStatus == noErr else {
            emit("CMBlockBuffer replace status=\(replaceStatus)")
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            emit("CMSampleBufferCreateReady status=\(status) (\(avcc.count)B)")
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as NSArray?,
           let dict = attachments.firstObject as? NSMutableDictionary {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
            if keyframe {
                dict[kCMSampleAttachmentKey_NotSync] = kCFBooleanFalse
            }
        }
        return sampleBuffer
    }

    private func tearDownSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    /// True if AVCC payload contains an IDR slice (nal_unit_type == 5).
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

    deinit {
        tearDownSession()
    }
}
