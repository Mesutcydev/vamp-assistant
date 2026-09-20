// Adapted from ios-local-llm (MIT); see docs/QWEN-STREAMING-NOTICES.md.
import Foundation

// MARK: - QwenStreamTensorBytes

/// Raw payload bytes for one tensor or tensor row.
struct QwenStreamTensorBytes: Sendable {
    let location: QwenStreamTensorLocation
    let bytes: Data

    var byteCount: Int { bytes.count }
}

// MARK: - QwenStreamTensorStoreError

enum QwenStreamTensorStoreError: Error, Equatable, Sendable {
    case openFailed(path: String, errno: Int32)
    case closed(path: String)
    case readFailed(path: String, errno: Int32)
    case unexpectedEOF(path: String, expected: Int, received: Int)
    case offsetTooLarge(tensor: String)
    case invalidReadLength(tensor: String)
}

extension QwenStreamTensorStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code):
            return "Could not open \(path) (errno \(code))."
        case .closed(let path):
            return "The tensor store for \(path) is closed."
        case .readFailed(let path, let code):
            return "Reading \(path) failed (errno \(code))."
        case .unexpectedEOF(let path, let expected, let received):
            return "Reading \(path) hit EOF after \(received) of \(expected) bytes."
        case .offsetTooLarge(let tensor):
            return "Tensor '\(tensor)' has an offset that cannot be addressed."
        case .invalidReadLength(let tensor):
            return "Tensor '\(tensor)' has an invalid read length."
        }
    }
}

// MARK: - QwenStreamTensorStore
//
// Range-based tensor byte access. Implementations must not require the whole
// checkpoint to be resident: opening a 4+ GB model may only hold an fd.

protocol QwenStreamTensorStore: Sendable {
    func read(_ location: QwenStreamTensorLocation) async throws -> QwenStreamTensorBytes
    func close() async
}

// MARK: - QwenStreamPreadFile

/// Explicit file-range reads over a single descriptor. `pread` is stateless,
/// so concurrent reads share the fd safely; `close()` is synchronized and
/// idempotent.
final class QwenStreamPreadFile: @unchecked Sendable {
    let path: String
    let size: UInt64

    private let fd: Int32
    private let lock = NSCondition()
    private var activeReads = 0
    private var isClosed = false

    init(path: String) throws {
        self.path = path
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw QwenStreamTensorStoreError.openFailed(path: path, errno: errno)
        }
        self.fd = descriptor
        var info = stat()
        if fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
            self.size = UInt64(max(0, info.st_size))
        } else {
            Darwin.close(descriptor)
            throw QwenStreamTensorStoreError.openFailed(path: path, errno: EINVAL)
        }
    }

    /// Reads exactly `count` bytes at `offset`, retrying interrupted reads
    /// and failing with a typed error on EOF.
    func read(offset: UInt64, count: Int) throws -> Data {
        if count == 0 { return Data() }
        guard count > 0 else {
            throw QwenStreamTensorStoreError.invalidReadLength(tensor: path)
        }
        guard offset <= UInt64(Int64.max), UInt64(count) <= UInt64(Int64.max) - offset else {
            throw QwenStreamTensorStoreError.offsetTooLarge(tensor: path)
        }
        let descriptor = try openDescriptor()
        defer {
            lock.lock()
            activeReads -= 1
            lock.broadcast()
            lock.unlock()
        }

        var data = Data(count: count)
        var total = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw QwenStreamTensorStoreError.invalidReadLength(tensor: path)
            }
            while total < count {
                let request = count - total
                let result = pread(
                    descriptor,
                    base.advanced(by: total),
                    request,
                    off_t(offset) + off_t(total)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw QwenStreamTensorStoreError.readFailed(path: path, errno: errno)
                }
                if result == 0 {
                    throw QwenStreamTensorStoreError.unexpectedEOF(
                        path: path,
                        expected: count,
                        received: total
                    )
                }
                total += result
            }
        }
        return data
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        while activeReads > 0 { lock.wait() }
        Darwin.close(fd)
    }

    private func openDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            throw QwenStreamTensorStoreError.closed(path: path)
        }
        activeReads += 1
        return fd
    }

    deinit {
        close()
    }
}

// MARK: - QwenStreamPreadTensorStore

/// Default range-read backend: explicit `pread` into controlled buffers.
/// This is deliberately the first implementation — a 4+ GB checkpoint opened
/// through this store adds no resident payload pages of its own.
final class QwenStreamPreadTensorStore: QwenStreamTensorStore, @unchecked Sendable {
    let shardName: String
    private let file: QwenStreamPreadFile

    init(path: String, shardName: String) throws {
        self.shardName = shardName
        self.file = try QwenStreamPreadFile(path: path)
    }

    func read(_ location: QwenStreamTensorLocation) async throws -> QwenStreamTensorBytes {
        try Task.checkCancellation()
        let bytes = try readSync(location)
        try Task.checkCancellation()
        return bytes
    }

    /// Blocking range read. Callers on Swift concurrency threads should go
    /// through `QwenStreamTensorStoreSet`, which dispatches I/O on a bounded queue.
    /// Synchronous sub-range read (see `QwenStreamTensorStoreSet.readSlice`).
    func readSync(
        _ location: QwenStreamTensorLocation,
        byteOffset: UInt64,
        byteLength: Int
    ) throws -> Data {
        try file.read(
            offset: location.payloadOffset + byteOffset,
            count: byteLength
        )
    }

    func readSync(_ location: QwenStreamTensorLocation) throws -> QwenStreamTensorBytes {
        guard location.byteCount <= UInt64(Int.max) else {
            throw QwenStreamTensorStoreError.invalidReadLength(tensor: location.name)
        }
        let data = try file.read(
            offset: location.payloadOffset,
            count: Int(location.byteCount)
        )
        return QwenStreamTensorBytes(location: location, bytes: data)
    }

    func close() async {
        file.close()
    }
}

// MARK: - QwenStreamTensorStoreSet
//
// Maps shard names to stores and dispatches blocking reads onto a bounded
// concurrent queue so long file I/O does not occupy Swift concurrency
// threads. Concurrency is capped; no task-per-tensor fan-out.

enum QwenStreamReadPhase: String, Sendable, Equatable, Hashable {
    case load
    case prefill
    case decode
    case other
}

struct QwenStreamPhaseReadStats: Sendable, Equatable {
    var requestedBytes: UInt64 = 0
    var completedBytes: UInt64 = 0
    var totalReadSeconds: Double = 0
    var totalReads = 0
}

struct QwenStreamTensorStoreReadStats: Sendable, Equatable {
    var totalRequestedBytes: UInt64 = 0
    var totalCompletedBytes: UInt64 = 0
    /// Time spent inside the synchronous range read, excluding time waiting
    /// for a bounded I/O slot. This is a storage-read observation, not a
    /// claim about physical SSD traffic because the kernel may serve pages
    /// from its file cache.
    var totalReadSeconds: Double = 0
    var configuredMaxConcurrentReads = 0
    var peakConcurrentReads = 0
    /// Reads submitted to the bounded I/O queue but not yet admitted to a
    /// semaphore slot. This is a developer-only quiescence observation; it
    /// prevents a cancellation test from treating a queued read as drained
    /// merely because no synchronous pread is active at the instant sampled.
    var queuedReadsAtSnapshot = 0
    var activeReadsAtSnapshot = 0
    var totalReads = 0
    var phase: QwenStreamReadPhase = .load
    var phases: [QwenStreamReadPhase: QwenStreamPhaseReadStats] = [
        .load: QwenStreamPhaseReadStats(),
        .prefill: QwenStreamPhaseReadStats(),
        .decode: QwenStreamPhaseReadStats(),
        .other: QwenStreamPhaseReadStats(),
    ]

    func stats(for phase: QwenStreamReadPhase) -> QwenStreamPhaseReadStats {
        phases[phase] ?? QwenStreamPhaseReadStats()
    }
}

final class QwenStreamTensorStoreSet: @unchecked Sendable {
    private let stores: [String: QwenStreamPreadTensorStore]
    private let directory: URL
    private let ioQueue: DispatchQueue
    private let ioLimit: DispatchSemaphore
    private let readLock = NSLock()
    private var readStats = QwenStreamTensorStoreReadStats()

    init(
        directory: URL,
        shardNames: [String],
        maxConcurrentReads: Int = 4
    ) throws {
        var stores: [String: QwenStreamPreadTensorStore] = [:]
        stores.reserveCapacity(shardNames.count)
        for shard in shardNames {
            let url = try QwenStreamPaths.file(shard, in: directory)
            stores[shard] = try QwenStreamPreadTensorStore(
                path: url.path,
                shardName: shard
            )
        }
        self.directory = directory
        self.stores = stores
        self.ioQueue = DispatchQueue(
            label: "com.beetcode.qwen-stream.tensor-io",
            qos: .userInitiated,
            attributes: .concurrent
        )
        self.ioLimit = DispatchSemaphore(value: max(1, maxConcurrentReads))
        self.readStats.configuredMaxConcurrentReads = max(1, maxConcurrentReads)
    }

    /// Cheap concurrency counters: configured limit, observed peak, and
    /// active reads at the moment of the snapshot.
    func readStatistics() -> QwenStreamTensorStoreReadStats {
        readLock.lock()
        defer { readLock.unlock() }
        return readStats
    }

    /// Reads already admitted to the queue retain their original phase. This
    /// keeps prefill/decode byte deltas non-overlapping when the phase flips.
    func setReadPhase(_ phase: QwenStreamReadPhase) {
        readLock.lock()
        readStats.phase = phase
        readLock.unlock()
    }

    func read(_ location: QwenStreamTensorLocation) async throws -> QwenStreamTensorBytes {
        try Task.checkCancellation()
        return try await readSlice(
            location,
            byteOffset: 0,
            byteLength: Int(location.byteCount)
        )
    }

    /// Reads an arbitrary byte sub-range of a tensor's payload. Used for
    /// per-expert slices inside stacked expert tensors: the slice of one
    /// first-axis row is contiguous, so `rowByteCount * index` addresses it
    /// without materializing the full tensor.
    func readSlice(
        _ location: QwenStreamTensorLocation,
        byteOffset: UInt64,
        byteLength: Int
    ) async throws -> QwenStreamTensorBytes {
        try Task.checkCancellation()
        guard let store = stores[location.shard] else {
            throw QwenStreamSafetensorsError.unknownShard(location.shard)
        }
        guard byteLength >= 0,
              byteOffset <= location.byteCount,
              UInt64(byteLength) <= location.byteCount - byteOffset else {
            throw QwenStreamTensorStoreError.invalidReadLength(tensor: location.name)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.readLock.lock()
            self.readStats.queuedReadsAtSnapshot += 1
            self.readLock.unlock()
            ioQueue.async {
                self.ioLimit.wait()
                self.readLock.lock()
                self.readStats.queuedReadsAtSnapshot = max(
                    0, self.readStats.queuedReadsAtSnapshot - 1)
                let phase = self.readStats.phase
                self.readStats.activeReadsAtSnapshot += 1
                self.readStats.totalReads += 1
                self.readStats.totalRequestedBytes += UInt64(byteLength)
                var phaseStats = self.readStats.stats(for: phase)
                phaseStats.requestedBytes += UInt64(byteLength)
                phaseStats.totalReads += 1
                self.readStats.phases[phase] = phaseStats
                self.readStats.peakConcurrentReads = max(
                    self.readStats.peakConcurrentReads,
                    self.readStats.activeReadsAtSnapshot
                )
                self.readLock.unlock()
                let readStarted = DispatchTime.now().uptimeNanoseconds
                var completed = false
                defer {
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- readStarted
                    self.readLock.lock()
                    self.readStats.totalReadSeconds += Double(elapsed) / 1_000_000_000
                    var phaseStats = self.readStats.stats(for: phase)
                    phaseStats.totalReadSeconds += Double(elapsed) / 1_000_000_000
                    if completed {
                        self.readStats.totalCompletedBytes += UInt64(byteLength)
                        phaseStats.completedBytes += UInt64(byteLength)
                    }
                    self.readStats.phases[phase] = phaseStats
                    self.readStats.activeReadsAtSnapshot -= 1
                    self.readLock.unlock()
                    self.ioLimit.signal()
                }
                do {
                    let bytes = try store.readSync(
                        location, byteOffset: byteOffset, byteLength: byteLength
                    )
                    completed = true
                    continuation.resume(returning: QwenStreamTensorBytes(
                        location: location, bytes: bytes
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Deterministically closes every shard. Outstanding reads that already
    /// entered `read` complete first because `read` holds the store only for
    /// the duration of one synchronous pread; closed descriptors cause new
    /// reads to fail with a typed error.
    func closeAll() async {
        for store in stores.values {
            await store.close()
        }
    }
}
