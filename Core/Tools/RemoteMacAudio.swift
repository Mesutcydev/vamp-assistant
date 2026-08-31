import AppKit
import AudioToolbox
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

final class RemoteMacAudio: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = RemoteMacAudio()

    struct Chunk: Sendable {
        let data: Data
        let sampleRate: Int
        let channels: Int
    }

    private struct State {
        var stream: SCStream?
        var starting = false
        var continuations: [UUID: AsyncStream<Chunk>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sessionDidLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func outputStream() -> AsyncStream<Chunk> {
        AsyncStream(bufferingPolicy: .bufferingNewest(12)) { continuation in
            let id = UUID()
            let shouldStart = state.withLock { state -> Bool in
                state.continuations[id] = continuation
                guard state.stream == nil, !state.starting else { return false }
                state.starting = true
                return true
            }
            if shouldStart {
                Task { await startIfNeeded() }
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    private func remove(_ id: UUID) {
        let shouldStop = state.withLock { state -> Bool in
            state.continuations.removeValue(forKey: id)
            return state.continuations.isEmpty && !state.starting
        }
        if shouldStop { Task { await stop() } }
    }

    private func startIfNeeded() async {
        guard !ComputerPermission.sessionLocked else {
            finishListeners()
            return
        }
        guard ComputerPermission.screenRecordingGranted else {
            finishListeners()
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                finishListeners()
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            let next = SCStream(filter: filter, configuration: config, delegate: self)
            try next.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "beet.remote.audio")
            )
            try await next.startCapture()
            let keepStream = state.withLock { state -> Bool in
                state.starting = false
                guard !state.continuations.isEmpty else { return false }
                state.stream = next
                return true
            }
            if !keepStream {
                try? await next.stopCapture()
            }
        } catch {
            finishListeners()
        }
    }

    private func finishListeners() {
        let (stream, listeners) = state.withLock { state -> (SCStream?, [AsyncStream<Chunk>.Continuation]) in
            let stream = state.stream
            state.stream = nil
            state.starting = false
            let listeners = Array(state.continuations.values)
            state.continuations.removeAll()
            return (stream, listeners)
        }
        if let stream { Task { try? await stream.stopCapture() } }
        listeners.forEach { $0.finish() }
    }

    private func stop() async {
        let current = state.withLock { state -> SCStream? in
            let current = state.stream
            state.stream = nil
            state.starting = false
            return current
        }
        try? await current?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let chunk = Self.pcmChunk(from: sampleBuffer) else { return }
        let listeners = state.withLock { Array($0.continuations.values) }
        listeners.forEach { $0.yield(chunk) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        finishListeners()
    }

    @objc private func sessionDidLock() {
        finishListeners()
    }

    private static func pcmChunk(from sampleBuffer: CMSampleBuffer) -> Chunk? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            return nil
        }

        var bufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bufferListSize > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<Int>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retained
        )
        guard status == noErr else { return nil }

        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let sampleRate = Int(asbd.mSampleRate == 0 ? 48_000 : asbd.mSampleRate)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var planes: [[Int16]] = []
        planes.reserveCapacity(buffers.count)

        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            for buffer in buffers {
                guard let pointer = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let floats = pointer.bindMemory(to: Float.self, capacity: count)
                planes.append((0..<count).map { index in
                    let clipped = max(-1, min(1, floats[index]))
                    return Int16(clipped * 32767)
                })
            }
        } else if asbd.mBitsPerChannel == 16 {
            for buffer in buffers {
                guard let pointer = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = pointer.bindMemory(to: Int16.self, capacity: count)
                planes.append(Array(UnsafeBufferPointer(start: samples, count: count)))
            }
        } else {
            return nil
        }

        guard let firstPlane = planes.first, !firstPlane.isEmpty else { return nil }
        let samples: [Int16]
        if isNonInterleaved, planes.count >= channels {
            let frameCount = planes.prefix(channels).map(\.count).min() ?? 0
            guard frameCount > 0 else { return nil }
            var interleaved: [Int16] = []
            interleaved.reserveCapacity(frameCount * channels)
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    interleaved.append(planes[channel][frame])
                }
            }
            samples = interleaved
        } else {
            samples = firstPlane
        }

        return Chunk(
            data: samples.withUnsafeBytes { Data($0) },
            sampleRate: sampleRate,
            channels: channels
        )
    }
}
