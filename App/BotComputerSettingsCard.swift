import SwiftUI

struct BotsTab: View {
    var body: some View {
        TabScroll { BotComputerSettingsCard() }
    }
}

struct BotComputerSettingsCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(
            title: "Bot computers",
            icon: "square.stack.3d.up.fill",
            footer: "Each bot gets private files and a browser profile. Linux micro-VMs use Apple's native container runtime and only start when you ask."
        ) {
            capabilityRow

            botSpaceSummary

            ForEach(appState.botComputers.computers) { computer in
                Divider()
                computerRow(computer)
            }

            if let error = appState.botComputers.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    appState.botComputers.prepareDefault()
                } label: {
                    Label("Prepare bot computer", systemImage: "plus")
                }
                .disabled(appState.botComputers.isWorking)

                if appState.botComputers.isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Refresh") { appState.botComputers.reload() }
                    .disabled(appState.botComputers.isWorking)
            }
        }
        .task { appState.botComputers.reload() }
    }

    private var botSpaceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How bot spaces work", systemImage: "lock.square.stack.fill")
                .font(.callout.weight(.semibold))
            Text("Each Linux micro-VM is capped at 2 CPU cores and 2 GB RAM. Its workspace and browser profile are private to that bot. Stopping it releases the VM memory while keeping its files for the next run.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var capabilityRow: some View {
        SettingRow(
            label: "This Mac",
            value: appState.botComputers.capabilities.map {
                "\($0.architecture) · \($0.macOSVersion)"
            } ?? "Checking host capabilities…"
        ) {
            HStack(spacing: 6) {
                Circle()
                    .fill(containerReady ? Theme.success : Theme.warning)
                    .frame(width: 7, height: 7)
                Text(containerReady ? "Micro-VM ready" : "Workspace isolation")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func computerRow(_ computer: BotComputerRecord) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accent.opacity(0.13))
                Image(systemName: computer.backend == .appleContainer
                    ? "cube.transparent.fill" : "folder.fill")
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(computer.name).font(.callout.weight(.semibold))
                Text("\(computer.backend.title) · \(computer.state.rawValue.capitalized)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(computer.workspacePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if computer.backend == .appleContainer {
                if computer.state == .running {
                    Button("Stop") { appState.botComputers.stop(computer) }
                } else {
                    Button("Start") { appState.botComputers.start(computer) }
                        .help("The first start may download a small Linux image.")
                }
            }
        }
    }

    private var containerReady: Bool {
        appState.botComputers.capabilities?.appleContainerServiceRunning == true
    }
}
