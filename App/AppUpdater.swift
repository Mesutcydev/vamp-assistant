import Combine
import Observation
import Sparkle
import SwiftUI

/// One updater for every app window. Sparkle owns its preferences and schedule.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var started = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                Task { @MainActor in self?.canCheckForUpdates = value }
            }
            .store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] value in
                Task { @MainActor in self?.automaticallyChecksForUpdates = value }
            }
            .store(in: &subscriptions)
    }

    func start() {
        // App-hosted tests must never prompt for updates or contact the feed.
        guard !started,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }
}

struct CheckForUpdatesButton: View {
    private let updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}

struct AppUpdateSettings: View {
    private let updater = AppUpdater.shared

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }

    var body: some View {
        SettingsCard(title: "Updates", icon: "arrow.down.circle",
                     footer: "Vamp Assistant checks for updates daily when enabled. You choose when to install an update.") {
            SettingRow(label: "Version", value: version) {
                CheckForUpdatesButton()
                    .buttonStyle(LFCapsuleButtonStyle())
            }
            SettingToggle(label: "Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }))
        }
    }
}
