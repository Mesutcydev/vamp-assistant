import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import os
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Continuous ScreenCaptureKit stream → VideoToolbox H.264 for Mac Control.
/// Capture dimensions follow **pixel** size (like Vamp), not AppKit points.
final class RemoteMacScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = RemoteMacScreenCapture()

    struct Config: Equatable, Sendable {
        var displayID: CGDirectDisplayID?
        var windowID: CGWindowID?
        var maxWidth: Int?
        var averageBitrate: Int
        var framesPerSecond: Int

        init(
            displayID: CGDirectDisplayID? = nil,
            windowID: CGWindowID? = nil,
            maxWidth: Int? = RemoteStreamResolution.high.maxWidth,
            averageBitrate: Int = RemoteStreamResolution.high.averageBitrate,
            framesPerSecond: Int = RemoteStreamResolution.high.framesPerSecond
        ) {
            self.displayID = displayID
            self.windowID = windowID
            self.maxWidth = maxWidth
            self.averageBitrate = max(averageBitrate, 250_000)
            self.framesPerSecond = min(max(framesPerSecond, 5), 60)
        }
    }

    typealias Frame = RemoteMacControl.Frame

    private struct State {
        var stream: SCStream?
        var starting = false
        var config = Config()
        var activeBounds = CGDisplayBounds(CGMainDisplayID())
        var latest: Frame?
        var continuations: [UUID: AsyncStream<Frame>.Continuation] = [:]
        var captureWidth = 0
        var captureHeight = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let encoder = RemoteH264Encoder()

    func frames(config: Config) -> AsyncStream<Frame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let id = UUID()
            let shouldStart = state.withLock { state -> Bool in
                let needsRestart = state.stream != nil && state.config != config
                state.config = config
                state.continuations[id] = continuation
                // New subscriber needs an IDR; do not replay a mid-GOP cached frame.
                if let latest = state.latest, case .h264(_, true, _) = latest.payload {
                    continuation.yield(latest)
                }
                if needsRestart {
                    return true
                }
                guard state.stream == nil, !state.starting else { return false }
                state.starting = true
                return true
            }
            // Force an IDR so the new phone can start decoding immediately.
            encoder.forceKeyframe()
            if shouldStart {
                Task { await restart(with: config) }
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    /// Prefer a still JPEG capture — live frames are H.264 only.
    func latestFrame(config: Config) async throws -> Frame {
        try await RemoteMacControl.captureDisplayJPEG(
            displayID: config.displayID,
            maxWidth: config.maxWidth)
    }

    private func remove(_ id: UUID) {
        let shouldStop = state.withLock { state -> Bool in
            state.continuations.removeValue(forKey: id)
            return state.continuations.isEmpty && !state.starting
        }
        if shouldStop { Task { await stop() } }
    }

    private func restart(with config: Config) async {
        await stop()
        state.withLock { state in
            state.config = config
            state.starting = true
            state.latest = nil
        }
        encoder.forceKeyframe()
        await startIfNeeded()
    }

    private func startIfNeeded() async {
        guard ComputerPermission.screenRecordingGranted else {
            finishListeners()
            return
        }

        let config = state.withLock { $0.config }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let targetWindow = config.windowID.flatMap { requestedID in
                content.windows.first { $0.windowID == requestedID && $0.isOnScreen }
            }
            if config.windowID != nil, targetWindow == nil {
                finishListeners()
                return
            }
            let display: SCDisplay
            if let displayID = config.displayID,
               let match = content.displays.first(where: { $0.displayID == displayID }) {
                display = match
            } else if let targetWindow,
                      let match = content.displays.max(by: {
                          CGDisplayBounds($0.displayID).intersection(targetWindow.frame).area
                              < CGDisplayBounds($1.displayID).intersection(targetWindow.frame).area
                      }) {
                display = match
            } else if let first = content.displays.first {
                display = first
            } else {
                finishListeners()
                return
            }

            let displayBounds = CGDisplayBounds(display.displayID)
            let filter: SCContentFilter
            let captureBounds: CGRect
            let pixelWidth: Int
            let pixelHeight: Int
            if let targetWindow {
                filter = SCContentFilter(desktopIndependentWindow: targetWindow)
                captureBounds = targetWindow.frame
                let backingScale = max(Double(display.width) / max(displayBounds.width, 1), 1)
                pixelWidth = max(Int((targetWindow.frame.width * backingScale).rounded()), 1)
                pixelHeight = max(Int((targetWindow.frame.height * backingScale).rounded()), 1)
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
                captureBounds = displayBounds
                pixelWidth = max(display.width, 1)
                pixelHeight = max(display.height, 1)
            }
            let streamConfig = SCStreamConfiguration()
            streamConfig.showsCursor = true
            streamConfig.queueDepth = 2
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.framesPerSecond))
            let scale = config.maxWidth.map { min(1, Double($0) / Double(pixelWidth)) } ?? 1
            let width = max(2, Int((Double(pixelWidth) * scale).rounded(.down) / 2) * 2)
            let height = max(2, Int((Double(pixelHeight) * scale).rounded(.down) / 2) * 2)
            streamConfig.width = width
            streamConfig.height = height
            streamConfig.scalesToFit = true
            // Prefer NV12 (encoder-friendly); fall back to BGRA if SCKit rejects it.
            streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

            encoder.configure(
                width: width,
                height: height,
                averageBitrate: config.averageBitrate,
                expectedFPS: config.framesPerSecond
            ) { [weak self] encoded in
                self?.publish(encoded: encoded)
            }
            encoder.forceKeyframe()

            let next = SCStream(filter: filter, configuration: streamConfig, delegate: self)
            try next.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "beet.remote.screen", qos: .userInteractive)
            )
            do {
                try await next.startCapture()
            } catch {
                streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
                let fallback = SCStream(filter: filter, configuration: streamConfig, delegate: self)
                try fallback.addStreamOutput(
                    self,
                    type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "beet.remote.screen", qos: .userInteractive)
                )
                try await fallback.startCapture()
                let keepFallback = state.withLock { state -> Bool in
                    state.starting = false
                    guard !state.continuations.isEmpty else { return false }
                    state.stream = fallback
                    state.activeBounds = captureBounds
                    state.captureWidth = width
                    state.captureHeight = height
                    return true
                }
                if !keepFallback {
                    try? await fallback.stopCapture()
                }
                return
            }
            let keepStream = state.withLock { state -> Bool in
                state.starting = false
                guard !state.continuations.isEmpty else { return false }
                state.stream = next
                state.activeBounds = captureBounds
                state.captureWidth = width
                state.captureHeight = height
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
        let listeners = state.withLock { state -> [AsyncStream<Frame>.Continuation] in
            state.stream = nil
            state.starting = false
            state.latest = nil
            let listeners = Array(state.continuations.values)
            state.continuations.removeAll()
            return listeners
        }
        encoder.invalidate()
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
        encoder.invalidate()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let hasListeners = state.withLock { !$0.continuations.isEmpty }
        guard hasListeners else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Drop if encoder is busy — latest frame wins on the next sample.
        guard !encoder.isBusy else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        _ = encoder.encode(pixelBuffer, presentationTime: pts)
    }

    private func publish(encoded: RemoteH264Encoder.EncodedFrame) {
        let bounds = state.withLock { $0.activeBounds }
        let frame = Frame(
            payload: .h264(
                data: encoded.data,
                keyframe: encoded.isKeyframe,
                parameterSets: encoded.parameterSets),
            imageWidth: encoded.width,
            imageHeight: encoded.height,
            displayX: bounds.origin.x,
            displayY: bounds.origin.y,
            displayWidth: bounds.width,
            displayHeight: bounds.height)
        let listeners = state.withLock { state -> [AsyncStream<Frame>.Continuation] in
            state.latest = frame
            return Array(state.continuations.values)
        }
        listeners.forEach { $0.yield(frame) }
    }

    /// Still JPEG helper for one-shot screenshots.
    static func jpegData(from cgImage: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.2), 0.95),
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
