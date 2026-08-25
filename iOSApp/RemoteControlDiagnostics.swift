import Foundation
import SwiftUI
import UIKit

/// Shared Control breadcrumbs — written during Mac Control, read from Settings.
@MainActor
final class RemoteControlDiagnostics: ObservableObject {
    static let shared = RemoteControlDiagnostics()

    struct Crumb: Identifiable, Equatable {
        let id: UInt64
        let at: Date
        let message: String
    }

    @Published private(set) var phase = "idle"
    @Published private(set) var crumbs: [Crumb] = []
    @Published private(set) var streamBytes = 0
    @Published private(set) var framesReceived = 0
    @Published private(set) var keyframesReceived = 0
    @Published private(set) var framesDecoded = 0
    @Published private(set) var decodeErrors = 0
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt = Date()

    private var nextID: UInt64 = 1
    private let limit = 80

    private init() {}

    func resetSession() {
        crumbs.removeAll(keepingCapacity: true)
        streamBytes = 0
        framesReceived = 0
        keyframesReceived = 0
        framesDecoded = 0
        decodeErrors = 0
        lastError = nil
        phase = "idle"
        breadcrumb("session reset")
    }

    func setPhase(_ value: String) {
        phase = value
        breadcrumb("phase → \(value)")
    }

    func breadcrumb(_ message: String) {
        let crumb = Crumb(id: nextID, at: Date(), message: message)
        nextID &+= 1
        crumbs.append(crumb)
        if crumbs.count > limit {
            crumbs.removeFirst(crumbs.count - limit)
        }
        updatedAt = Date()
    }

    func noteStreamHeaders(status: Int, boundary: String) {
        breadcrumb("HTTP \(status) boundary=\(boundary)")
        setPhase("stream open")
    }

    func noteStreamData(bytes: Int) {
        streamBytes += bytes
    }

    func noteFrame(bytes: Int, keyframe: Bool, hasParams: Bool, size: String) {
        framesReceived &+= 1
        if keyframe { keyframesReceived &+= 1 }
        if framesReceived <= 3 || keyframe || framesReceived % 30 == 0 {
            breadcrumb(
                "frame#\(framesReceived) \(bytes)B kf=\(keyframe ? 1 : 0) params=\(hasParams ? 1 : 0) \(size)"
            )
        }
        if keyframe && !hasParams {
            lastError = "Keyframe missing parameter sets"
            breadcrumb("WARN keyframe without SPS/PPS")
        }
        setPhase(framesDecoded > 0 ? "playing" : "decoding")
    }

    func noteDecodeOK() {
        framesDecoded &+= 1
        if framesDecoded == 1 {
            breadcrumb("first decoded pixel")
            setPhase("playing")
        }
        updatedAt = Date()
    }

    func noteDecodeError(_ message: String) {
        decodeErrors &+= 1
        lastError = message
        if decodeErrors <= 5 || decodeErrors % 20 == 0 {
            breadcrumb("decode err: \(message)")
        }
        setPhase("decode wait")
    }

    func noteError(_ message: String) {
        lastError = message
        breadcrumb("ERROR \(message)")
    }

    func clear() {
        crumbs.removeAll(keepingCapacity: true)
        streamBytes = 0
        framesReceived = 0
        keyframesReceived = 0
        framesDecoded = 0
        decodeErrors = 0
        lastError = nil
        phase = "idle"
        updatedAt = Date()
    }

    var exportText: String {
        var lines: [String] = [
            "Vamp Assistant Remote Control Diagnostics",
            "phase=\(phase)",
            "streamBytes=\(streamBytes) frames=\(framesReceived) keyframes=\(keyframesReceived)",
            "decoded=\(framesDecoded) decodeErrors=\(decodeErrors)",
            "lastError=\(lastError ?? "—")",
            "--- breadcrumbs ---",
        ]
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        for crumb in crumbs {
            lines.append("\(formatter.string(from: crumb.at))  \(crumb.message)")
        }
        return lines.joined(separator: "\n")
    }
}

struct RemoteDiagnosticsSettingsView: View {
    @ObservedObject private var diagnostics = RemoteControlDiagnostics.shared
    @Environment(\.remoteAppearance) private var appearance
    @State private var copied = false

    var body: some View {
        ZStack {
            RemoteBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    if let lastError = diagnostics.lastError {
                        errorCard(lastError)
                    }
                    breadcrumbsCard
                    actions
                }
                .padding(16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Control Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LIVE STATE")
                .font(.caption2.bold())
                .tracking(0.8)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            labeled("Phase", diagnostics.phase)
            labeled("Frames received", "\(diagnostics.framesReceived)")
            labeled("Keyframes", "\(diagnostics.keyframesReceived)")
            labeled("Decoded", "\(diagnostics.framesDecoded)")
            labeled("Decode errors", "\(diagnostics.decodeErrors)")
            labeled("Stream bytes", ByteCountFormatter.string(fromByteCount: Int64(diagnostics.streamBytes), countStyle: .memory))
            labeled("Updated", diagnostics.updatedAt.formatted(date: .omitted, time: .standard))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(BeetTheme.line(appearance)) }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LAST ERROR")
                .font(.caption2.bold())
                .tracking(0.8)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(white: 0.72))
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.35)) }
    }

    private var breadcrumbsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BREADCRUMBS")
                .font(.caption2.bold())
                .tracking(0.8)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            if diagnostics.crumbs.isEmpty {
                Text("Open Mac Control once to start collecting breadcrumbs.")
                    .font(.subheadline)
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
            } else {
                ForEach(diagnostics.crumbs.reversed()) { crumb in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(crumb.at.formatted(date: .omitted, time: .standard))
                            .font(.caption2.monospaced())
                            .foregroundStyle(BeetTheme.secondaryText(appearance))
                        Text(crumb.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(appearance == .light ? Color.primary : Color.white)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                    if crumb.id != diagnostics.crumbs.first?.id {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(BeetTheme.line(appearance)) }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = diagnostics.exportText
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy diagnostics", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(RemotePrimaryButtonStyle())

            Button(role: .destructive) {
                diagnostics.clear()
                copied = false
            } label: {
                Label("Clear log", systemImage: "trash")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(RemoteSecondaryButtonStyle())
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(appearance == .light ? Color.primary : Color.white)
                .multilineTextAlignment(.trailing)
        }
    }
}
