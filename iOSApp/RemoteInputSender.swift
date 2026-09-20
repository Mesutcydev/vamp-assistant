import Foundation
import Observation
import SwiftUI

#if canImport(UIKit)
import UIKit

/// Vamp-style ordered input pipeline: motion coalesces and flushes once per display refresh.
@MainActor
@Observable
final class RemoteInputSender {
    typealias Command = RemoteInputCommand
    typealias SendCommand = @MainActor @Sendable (Command) async throws -> Void
    typealias SendCommands = @MainActor @Sendable ([Command]) async throws -> Void

    private let sendCommands: SendCommands
    private var pending = RemoteInputCommandBuffer()
    private var outbound = RemoteInputCommandBuffer()
    private var sendTask: Task<Void, Never>?
    private var isStopping = false
    private var flushLink: CADisplayLink?
    private var flushProxy: DisplayLinkProxy?

    static let maxBatchSize = 64
    /// Vamp Control keeps at most one pending move and one pending scroll. This
    /// is the HTTP equivalent: a slow request must not turn every display frame
    /// into another stale request behind it.
    static let maxPendingMotion = 2
    static let maxOutboundMotion = 2

    private(set) var pendingCount = 0
    private(set) var sentCount: UInt64 = 0
    private(set) var coalescedCount: UInt64 = 0
    private(set) var failedCount: UInt64 = 0
    private(set) var lastRoundTripMilliseconds: Int?
    private(set) var lastError: String?

    init(sendCommand: @escaping SendCommand) {
        self.sendCommands = { commands in
            for command in commands {
                try await sendCommand(command)
            }
        }
    }

    init(sendCommands: @escaping SendCommands) {
        self.sendCommands = sendCommands
    }

    isolated deinit {
        // CADisplayLink isn't Sendable; invalidate from MainActor teardown paths instead.
        sendTask?.cancel()
    }

    func enqueue(_ command: Command) {
        guard !isStopping else { return }
        let wasCoalesced = pending.append(command)
        if wasCoalesced { coalescedCount &+= 1 }
        pending.trimMotion(keeping: Self.maxPendingMotion)
        pendingCount = pending.count + outbound.count
        if command.isMotion && !pending.containsBarrier {
            ensureFlushLink()
        } else {
            flushNow()
        }
    }

    func stop(flushing command: Command? = nil) {
        isStopping = true
        stopFlushLink()
        pending.removeAll()
        outbound.removeAll()
        if let command {
            pending.append(command)
            pendingCount = pending.count + outbound.count
            flushNow()
        } else {
            pendingCount = 0
        }
    }

    func reset() {
        isStopping = false
        stopFlushLink()
        pending.removeAll()
        outbound.removeAll()
        pendingCount = 0
        sendTask?.cancel()
        sendTask = nil
        lastError = nil
        lastRoundTripMilliseconds = nil
    }

    /// Force a flush (e.g. drag ended) so the final sample lands precisely — Vamp `flushPending`.
    func flush() {
        flushNow()
    }

    private func ensureFlushLink() {
        guard flushLink == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] in
            self?.flushNow()
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        flushProxy = proxy
        flushLink = link
    }

    private func stopFlushLink() {
        flushLink?.invalidate()
        flushLink = nil
        flushProxy = nil
    }

    private func flushNow() {
        guard !pending.isEmpty || !outbound.isEmpty else {
            pendingCount = 0
            stopFlushLink()
            return
        }

        if sendTask != nil {
            let incoming = pending.drain(maxCount: Self.maxBatchSize)
            for command in incoming {
                _ = outbound.append(command)
            }
            outbound.trimMotion(keeping: Self.maxOutboundMotion)
            pendingCount = pending.count + outbound.count
            if pending.isEmpty {
                stopFlushLink()
            }
            return
        }

        let commands: [Command]
        if outbound.isEmpty {
            commands = pending.drain(maxCount: Self.maxBatchSize)
        } else {
            commands = outbound.drain(maxCount: Self.maxBatchSize)
        }
        pendingCount = pending.count
        if pending.isEmpty {
            stopFlushLink()
        }
        guard !commands.isEmpty else { return }

        sendTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try await self.sendCommands(commands)
                self.sentCount &+= UInt64(commands.count)
                self.lastRoundTripMilliseconds = Int(
                    ((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
                self.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                self.failedCount &+= 1
                self.lastError = error.localizedDescription
            }
            self.sendTask = nil
            if self.isStopping, self.outbound.isEmpty {
                self.pendingCount = self.pending.count
                return
            }
            self.flushNow()
        }
    }
}

/// CADisplayLink needs an NSObject target; keep a thin proxy so the sender stays a Swift class.
private final class DisplayLinkProxy: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func tick() { handler() }
}
#endif
