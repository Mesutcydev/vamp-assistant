import AppKit
import Combine
import Observation
import SwiftUI

/// Pane resources belong to the window, never to a split's view lifetime.
@MainActor
@Observable
final class WorkspaceResources {
    let simulator = SimulatorContext()
    private var reviews: [String: ChangedFilesReviewModel] = [:]

    func review(for workspace: URL) -> ChangedFilesReviewModel {
        let key = workspace.standardizedFileURL.path
        if let existing = reviews[key] { return existing }
        let model = ChangedFilesReviewModel(workspace: workspace)
        reviews[key] = model
        return model
    }
}

/// The same snapshot drives Devices, settings and session details.
@MainActor
final class MacPermissionState: ObservableObject {
    static let shared = MacPermissionState()
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var screenRecordingRequested = false
    private var observation: AnyCancellable?

    init() {
        refresh()
        observation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    func refresh() {
        accessibilityGranted = ComputerPermission.accessibilityGranted
        screenRecordingGranted = ComputerPermission.screenRecordingGranted
    }

    func requestAccessibility() {
        ComputerPermission.requestAccessibility()
        refresh()
    }

    func requestScreenRecording() {
        screenRecordingRequested = true
        ComputerPermission.requestScreenRecording()
        refresh()
    }
}

struct MacPermissionRows: View {
    @ObservedObject private var permissions = MacPermissionState.shared

    var body: some View {
        VStack(spacing: 12) {
            row("Accessibility", detail: "Read app interfaces and send mouse or keyboard input",
                granted: permissions.accessibilityGranted, pending: false,
                action: permissions.requestAccessibility)
            row("Screen Recording", detail: "Capture windows and screens",
                granted: permissions.screenRecordingGranted,
                pending: permissions.screenRecordingRequested && !permissions.screenRecordingGranted,
                action: permissions.requestScreenRecording)
        }
        .safeAreaInset(edge: .bottom) {
            if permissions.screenRecordingRequested && !permissions.screenRecordingGranted {
                Text("After granting Screen Recording in System Settings, quit and reopen if macOS requires it.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { permissions.refresh() }
    }

    private func row(_ title: String, detail: String, granted: Bool,
                     pending: Bool, action: @escaping () -> Void) -> some View {
        SettingRow(label: title, value: detail) {
            HStack(spacing: 8) {
                Circle().fill(granted ? Theme.success : pending ? Theme.warning : Theme.textSecondary)
                    .frame(width: 6, height: 6).accessibilityHidden(true)
                Text(granted ? "Granted" : "Not granted")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                if !granted {
                    Button(pending ? "Open settings…" : "Grant…") {
                        if pending, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        } else { action() }
                    }.controlSize(.small).accessibilityLabel(pending ? "Open \(title) settings" : "Grant \(title)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(granted ? "Granted" : "Not granted")")
    }
}


/// Stores identities only. Credentials stay with their existing providers.
@MainActor
final class RecentModelSelections: ObservableObject {
    static let shared = RecentModelSelections()
    @Published private(set) var ids: [String]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.stringArray(forKey: "workspace-recent-models.v1") ?? []
    }
    func record(_ id: String) {
        guard !ProcessInfo.processInfo.arguments.contains("--design-preview") else { return }
        ids = Array(([id] + ids.filter { $0 != id }).prefix(8))
        defaults.set(ids, forKey: "workspace-recent-models.v1")
    }
}
