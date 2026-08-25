import Foundation
import SwiftUI

@MainActor
final class RemoteTerminalSession: ObservableObject {
    enum State: Equatable {
        case idle
        case opening
        case open
        case closed(String?)
        case failed(String)
    }

    struct OutputChunk: Identifiable, Equatable {
        let id: UInt64
        let data: Data
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var outputChunks: [OutputChunk] = []
    @Published private(set) var generation: UInt64 = 0

    private let store: RemoteStore
    private var outputTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputQueue: [Data] = []
    private var resizeTask: Task<Void, Never>?
    private var terminalOpened = false
    private var nextOutputID: UInt64 = 0

    init(store: RemoteStore) {
        self.store = store
    }

    deinit {
        outputTask?.cancel()
        openTask?.cancel()
        inputTask?.cancel()
        resizeTask?.cancel()
    }

    func open() {
        guard state == .idle || isClosed else { return }
        generation &+= 1
        let currentGeneration = generation
        outputChunks.removeAll(keepingCapacity: true)
        inputQueue.removeAll(keepingCapacity: true)
        inputTask?.cancel()
        inputTask = nil
        nextOutputID = 0
        state = .opening
        terminalOpened = false
        outputTask?.cancel()
        let stream = store.terminalOutput()
        outputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await chunk in stream {
                    guard !Task.isCancelled, self.generation == currentGeneration else { return }
                    append(chunk)
                }
                if !Task.isCancelled, self.generation == currentGeneration, state == .open {
                    state = .closed("Connection ended")
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                state = .failed(error.localizedDescription)
            }
        }
        openTask?.cancel()
        openTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            do {
                try await store.openTerminal()
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                terminalOpened = true
                state = .open
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                outputTask?.cancel()
                outputTask = nil
                state = .failed(error.localizedDescription)
            }
                openTask = nil
        }
    }

    func send(_ data: Data) {
        guard !data.isEmpty, data.count <= 16 * 1024, state == .open else { return }
        let queuedBytes = inputQueue.reduce(0) { $0 + $1.count }
        guard queuedBytes + data.count <= 64 * 1024 else { return }
        inputQueue.append(data)
        startInputTaskIfNeeded()
    }

    private func startInputTaskIfNeeded() {
        guard inputTask == nil else { return }
        inputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !inputQueue.isEmpty {
                let data = inputQueue.removeFirst()
                do {
                    try await store.sendTerminalInput(data)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    state = .failed(error.localizedDescription)
                    inputQueue.removeAll(keepingCapacity: true)
                    inputTask = nil
                    return
                }
            }
            inputTask = nil
        }
    }

    func resize(cols: Int, rows: Int) {
        guard state == .open else { return }
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                try await store.resizeTerminal(cols: cols, rows: rows)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func close() {
        let shouldCloseHost = terminalOpened || state == .opening || state == .open
        generation &+= 1
        outputTask?.cancel()
        outputTask = nil
        openTask?.cancel()
        openTask = nil
        inputTask?.cancel()
        inputTask = nil
        inputQueue.removeAll(keepingCapacity: true)
        resizeTask?.cancel()
        resizeTask = nil
        terminalOpened = false
        state = shouldCloseHost ? .closed("Closed") : .idle
        if shouldCloseHost {
            Task { @MainActor [store] in
                try? await store.closeTerminal()
            }
        }
    }

    private var isClosed: Bool {
        if case .closed = state { return true }
        if case .failed = state { return true }
        return false
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        nextOutputID &+= 1
        outputChunks.append(OutputChunk(id: nextOutputID, data: data))
        if outputChunks.count > 256 {
            outputChunks.removeFirst(outputChunks.count - 256)
        }
    }
}
