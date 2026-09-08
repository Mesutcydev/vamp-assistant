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

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(appState.botComputers.computers) { computer in
                    computerRow(computer)
                    if computer.id != appState.botComputers.computers.last?.id {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 0.75)
                            .padding(.vertical, Spacing.xs)
                    }
                }
            }

            if let error = appState.botComputers.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.app(size: 12 ))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.sm) {
                Button {
                    appState.botComputers.prepareDefault()
                } label: {
                    Label("Prepare specialist computers", systemImage: "plus")
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .disabled(appState.botComputers.isWorking || specialistsPrepared)

                if appState.botComputers.isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Refresh") { appState.botComputers.reload() }
                    .buttonStyle(LFCapsuleButtonStyle())
                    .disabled(appState.botComputers.isWorking)
            }
        }
        .task { appState.botComputers.reload() }
    }

    private var botSpaceSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How bot spaces work")
                .vampSectionLabel()
            Text("Each specialist bot (Builder, Reviewer, Navigator, Researcher) gets its own private files and in-app browser. Linux micro-VMs run a full guest shell inside the container. Stopping a VM keeps the files and browser logins for the next run.")
                .font(.app(size: 12 ))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceInset.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous))
    }

    private var capabilityRow: some View {
        SettingRow(
            label: "This Mac",
            value: appState.botComputers.capabilities.map {
                "\($0.architecture) · \($0.macOSVersion)"
            } ?? "Checking host capabilities…"
        ) {
            HStack(spacing: 6) {
                VampStatusDot(color: containerReady ? Theme.positive : Theme.warning)
                Text(containerReady ? "Micro-VM ready" : "Workspace isolation")
                    .font(.app(size: 12, weight: .medium ))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func computerRow(_ computer: BotComputerRecord) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: computer.backend == .appleContainer
                ? "cube.transparent" : "folder")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Theme.surfaceInset,
                            in: RoundedRectangle(cornerRadius: Chrome.buttonRadius,
                                                 style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(computer.name)
                    .font(.app(size: 13, weight: .medium ))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(computer.backend.title) · \(computer.state.rawValue.capitalized)")
                    .font(.app(size: 11 ))
                    .foregroundStyle(Theme.textSecondary)
                Text(computer.workspacePath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if computer.state == .unavailable {
                Text("Unavailable")
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textTertiary)
            } else if computer.state == .running {
                Button("Stop") { appState.botComputers.stop(computer) }
                    .buttonStyle(LFCapsuleButtonStyle())
            } else {
                Button("Start") { appState.botComputers.start(computer) }
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                    .help(computer.backend == .appleContainer
                        ? "The first start may download a small Linux image."
                        : "Marks this private workspace ready for a remote session.")
            }
        }
        .frame(minHeight: 34)
    }

    private var containerReady: Bool {
        appState.botComputers.capabilities?.appleContainerServiceRunning == true
    }

    private var specialistsPrepared: Bool {
        let ids = Set(appState.botComputers.computers.map(\.profileID))
        return BotComputerService.specialists.allSatisfy { ids.contains($0.id) }
    }
}
