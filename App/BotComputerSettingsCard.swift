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
            footer: "Builder, Reviewer, Navigator, and Researcher each get a private computer and in-app browser. Linux micro-VMs run a full guest shell (git, Python, Node, compilers) inside the container."
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
                    Label("Prepare specialist computers", systemImage: "plus")
                }
                .disabled(appState.botComputers.isWorking || specialistsPrepared)

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
            Text("Each specialist bot (Builder, Reviewer, Navigator, Researcher) gets its own private files and in-app browser. Linux micro-VMs run a full guest shell inside the container. Stopping a VM keeps the files and browser logins for the next run.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
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
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Theme.accent.opacity(0.13))
                Image(systemName: computer.backend == .appleContainer
                    ? "cube.transparent.fill" : "folder.fill")
                    .foregroundStyle(Theme.accentText)
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
            if computer.state == .unavailable {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else if computer.state == .running {
                Button("Stop") { appState.botComputers.stop(computer) }
            } else {
                Button("Start") { appState.botComputers.start(computer) }
                    .help(computer.backend == .appleContainer
                        ? "The first start may download a small Linux image."
                        : "Marks this private workspace ready for a remote session.")
            }
        }
    }

    private var containerReady: Bool {
        appState.botComputers.capabilities?.appleContainerServiceRunning == true
    }

    private var specialistsPrepared: Bool {
        let ids = Set(appState.botComputers.computers.map(\.profileID))
        return BotComputerService.specialists.allSatisfy { ids.contains($0.id) }
    }
}
