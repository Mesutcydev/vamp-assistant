import Darwin
import Foundation

/// One interactive Mac shell for the iPhone Control surface.
enum RemoteMacTerminal {
    private static let lock = NSLock()
    // Protected by `lock`.
    nonisolated(unsafe) private static var session: Session?
    nonisolated(unsafe) private static var pendingContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    fileprivate final class Session: @unchecked Sendable {
        let masterFD: Int32
        let childPID: pid_t
        var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]
        var outputHistory: [Data] = []
        var source: DispatchSourceRead?

        init(masterFD: Int32, childPID: pid_t) {
            self.masterFD = masterFD
            self.childPID = childPID
        }
    }

    @_silgen_name("forkpty")
    private static func c_forkpty(
        _ amaster: UnsafeMutablePointer<Int32>?,
        _ name: UnsafeMutablePointer<CChar>?,
        _ termp: UnsafePointer<termios>?,
        _ winp: UnsafePointer<winsize>?
    ) -> pid_t

    static func open(cols: UInt16 = 80, rows: UInt16 = 24) throws {
        closeActiveSession()
        var master: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let pid = c_forkpty(&master, nil, nil, &ws)
        guard pid >= 0 else {
            throw RemoteTerminalError.spawnFailed
        }
        if pid == 0 {
            execShell()
        }
        let session = Session(masterFD: master, childPID: pid)
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { return }
            let chunk = Data(buffer.prefix(count))
            lock.lock()
            session.outputHistory.append(chunk)
            if session.outputHistory.count > 64 {
                session.outputHistory.removeFirst(session.outputHistory.count - 64)
            }
            let listeners = Array(session.continuations.values)
            lock.unlock()
            for continuation in listeners { continuation.yield(chunk) }
        }
        source.setCancelHandler { Darwin.close(master) }
        session.source = source
        lock.lock()
        let listeners = pendingContinuations
        pendingContinuations.removeAll()
        session.continuations = listeners
        self.session = session
        lock.unlock()
        source.resume()
    }

    static func input(_ data: Data) {
        lock.lock()
        let fd = session?.masterFD
        lock.unlock()
        guard let fd, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = write(fd, base, data.count)
        }
    }

    static func resize(cols: UInt16, rows: UInt16) {
        lock.lock()
        let fd = session?.masterFD
        lock.unlock()
        guard let fd else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }

    static func close() {
        let (current, pending) = detachSession(includePending: true)
        terminate(current)
        current?.continuations.values.forEach { $0.finish() }
        pending.values.forEach { $0.finish() }
    }

    private static func closeActiveSession() {
        let (current, _) = detachSession(includePending: false)
        guard let current else { return }
        terminate(current)
        lock.lock()
        for (id, continuation) in current.continuations {
            pendingContinuations[id] = continuation
        }
        lock.unlock()
    }

    private static func detachSession(
        includePending: Bool
    ) -> (Session?, [UUID: AsyncStream<Data>.Continuation]) {
        lock.lock()
        let current = session
        session = nil
        let pending = includePending ? pendingContinuations : [:]
        if includePending { pendingContinuations.removeAll() }
        lock.unlock()
        return (current, pending)
    }

    private static func terminate(_ session: Session?) {
        session?.source?.cancel()
        if let session, session.childPID > 0 {
            kill(-session.childPID, SIGTERM)
        }
    }

    static func outputStream() -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let id = UUID()
            let history: [Data]
            lock.lock()
            if let session {
                session.continuations[id] = continuation
                history = session.outputHistory
            } else {
                pendingContinuations[id] = continuation
                history = []
            }
            lock.unlock()
            history.forEach { continuation.yield($0) }
            continuation.onTermination = { _ in
                lock.lock()
                session?.continuations.removeValue(forKey: id)
                pendingContinuations.removeValue(forKey: id)
                lock.unlock()
            }
        }
    }

    private static func execShell() -> Never {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        _ = chdir(home)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["HOME"] = home
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let inherited = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var path = inherited.split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        var envPointers = env.map { strdup("\($0.key)=\($0.value)") }
        envPointers.append(nil)
        let name = URL(fileURLWithPath: shell).lastPathComponent
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("-\(name)"), strdup("-i"), nil]
        envPointers.withUnsafeMutableBufferPointer { envBuf in
            argv.withUnsafeMutableBufferPointer { argBuf in
                _ = execve(shell, argBuf.baseAddress, envBuf.baseAddress)
            }
        }
        _exit(127)
    }
}

enum RemoteTerminalError: Error, LocalizedError {
    case spawnFailed
    var errorDescription: String? { "Could not open a Mac shell." }
}
