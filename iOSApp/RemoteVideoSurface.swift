import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

/// CVPixelBuffer is thread-safe for handoff after decode; wrap for Swift 6 Sendable checks.
struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Drives `RemoteVideoSurface` from decoded CVPixelBuffers.
@MainActor
final class RemoteVideoSurfaceBinder: ObservableObject {
    @Published private(set) var hasFrame = false
    let fillMode: AVLayerVideoGravity

    private weak var layer: AVSampleBufferDisplayLayer?
    private var frameCount = 0

    init(fillMode: AVLayerVideoGravity = .resizeAspect) {
        self.fillMode = fillMode
    }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
        layer.videoGravity = fillMode
    }

    func setFillMode(_ mode: AVLayerVideoGravity) {
        layer?.videoGravity = mode
    }

    func enqueue(_ wrapped: SendablePixelBuffer) {
        enqueue(wrapped.buffer)
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let layer else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
        }
        guard let sample = Self.makeSampleBuffer(from: pixelBuffer) else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
           let dict = attachments.firstObject as? NSMutableDictionary {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sample)
        } else {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            renderer.enqueue(sample)
        }
        if !hasFrame {
            hasFrame = true
        }
        frameCount &+= 1
    }

    func reset() {
        layer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        hasFrame = false
        frameCount = 0
    }

    private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}

struct RemoteVideoSurface: UIViewRepresentable {
    @ObservedObject var binder: RemoteVideoSurfaceBinder
    var fill: Bool

    func makeUIView(context: Context) -> RemoteVideoUIView {
        let view = RemoteVideoUIView()
        binder.attach(view.displayLayer)
        binder.setFillMode(fill ? .resizeAspectFill : .resizeAspect)
        return view
    }

    func updateUIView(_ uiView: RemoteVideoUIView, context: Context) {
        binder.attach(uiView.displayLayer)
        binder.setFillMode(fill ? .resizeAspectFill : .resizeAspect)
    }
}

final class RemoteVideoUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetRate(timebase, rate: 1.0)
            displayLayer.controlTimebase = timebase
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
