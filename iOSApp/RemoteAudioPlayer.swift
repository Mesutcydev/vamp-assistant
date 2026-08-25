import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class RemoteAudioPlayer: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var errorMessage: String?
    @Published var isMuted = false {
        didSet { playerNode?.volume = isMuted ? 0 : 1 }
    }

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var formatKey = ""
    private var scheduledFrames = 0
    private var sampleRate = 48_000.0

    func start() {
        guard !isActive else { return }
        isActive = true
        errorMessage = nil
        configureAudioSession()
    }

    func stop() {
        guard isActive || engine != nil else { return }
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        formatKey = ""
        scheduledFrames = 0
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func receive(_ chunk: RemoteMacAudioChunk) {
        guard isActive, !isMuted else { return }
        guard chunk.sampleRate >= 8_000,
              chunk.sampleRate <= 192_000,
              (1...8).contains(chunk.channelCount),
              !chunk.pcmData.isEmpty else { return }

        let key = "\(chunk.sampleRate)-\(chunk.channelCount)"
        if key != formatKey {
            guard rebuild(sampleRate: chunk.sampleRate, channelCount: chunk.channelCount) else { return }
        }
        guard let playerNode, let format = playerNode.outputFormat(forBus: 0).sampleRate > 0 ? playbackFormat : nil else { return }
        guard let buffer = makeBuffer(from: chunk.pcmData, format: format, channelCount: chunk.channelCount) else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        if scheduledFrames > Int(sampleRate * 0.12) {
            playerNode.stop()
            scheduledFrames = 0
            playerNode.play()
        }
        scheduledFrames += frameCount
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                self?.scheduledFrames = max(0, (self?.scheduledFrames ?? 0) - frameCount)
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    private var playbackFormat: AVAudioFormat? {
        let parts = formatKey.split(separator: "-").map(String.init)
        guard parts.count == 2,
              let rate = Double(parts[0]),
              let channels = UInt32(parts[1]) else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )
    }

    private func rebuild(sampleRate: Double, channelCount: Int) -> Bool {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        scheduledFrames = 0
        self.sampleRate = sampleRate

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            errorMessage = "The Mac audio format is not supported."
            return false
        }

        let nextEngine = AVAudioEngine()
        let nextPlayer = AVAudioPlayerNode()
        nextEngine.attach(nextPlayer)
        nextEngine.connect(nextPlayer, to: nextEngine.mainMixerNode, format: format)
        nextEngine.mainMixerNode.outputVolume = 1
        nextPlayer.volume = isMuted ? 0 : 1
        nextEngine.prepare()

        do {
            try nextEngine.start()
        } catch {
            errorMessage = "Mac audio could not start."
            return false
        }

        engine = nextEngine
        playerNode = nextPlayer
        formatKey = "\(sampleRate)-\(channelCount)"
        errorMessage = nil
        return true
    }

    private func makeBuffer(
        from data: Data,
        format: AVAudioFormat,
        channelCount: Int
    ) -> AVAudioPCMBuffer? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount >= channelCount,
              sampleCount.isMultiple(of: channelCount) else { return nil }
        let frameCount = sampleCount / channelCount
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let sample = base[frame * channelCount + channel]
                    channels[channel][frame] = Float(sample) / 32768
                }
            }
        }
        return buffer
    }

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            errorMessage = "Mac audio permission or output is unavailable."
        }
        #endif
    }
}
