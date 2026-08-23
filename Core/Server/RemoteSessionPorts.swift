import Foundation

/// Remote Sessions listen on a Beet-owned port so the Mac app can run beside
/// Vamp Host. Vamp claims 9471–9473 and 9475 for signaling and Safari control.
enum RemoteSessionPorts {
    static let defaultPort = 9575
    static let reservedForeignPorts: Set<Int> = [9471, 9472, 9473, 9475]

    static func resolved(_ requested: Int) -> Int {
        if requested <= 0 || reservedForeignPorts.contains(requested) {
            return defaultPort
        }
        return requested
    }

    static func candidates(preferred: Int) -> [Int] {
        let start = resolved(preferred)
        var ports = [start]
        for offset in 1...8 {
            let next = start + offset
            if !reservedForeignPorts.contains(next) {
                ports.append(next)
            }
        }
        return ports
    }
}
