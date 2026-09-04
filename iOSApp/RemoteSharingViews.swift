import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RemoteShareSheet: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var showFileImporter = false
    @State private var downloadedFile: DownloadedRemoteFile?
    @State private var confirmation: String?

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ShareSheetHeader()
                        ClipboardSharingSection(store: store, confirmation: $confirmation)
                        FileSharingSection(
                            store: store,
                            onChooseFile: { showFileImporter = true },
                            onDownload: download
                        )
                    }
                    .frame(maxWidth: 620).padding(.horizontal, 18).padding(.bottom, 30).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Share with Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.loadSharing() }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task {
                    if await store.uploadFile(url) { confirmation = "Sent \(url.lastPathComponent) to your Mac." }
                }
            }
            .sheet(item: $downloadedFile) { item in RemoteActivityView(items: [item.url]) }
            .overlay(alignment: .bottom) {
                if let confirmation {
                    Text(confirmation).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .background(Color.black.opacity(0.82), in: Capsule())
                        .padding(.bottom, 18).transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation(.easeOut(duration: 0.18)) { self.confirmation = nil }
                        }
                }
            }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.92), for: .navigationBar)
        }
    }

    private func download(_ file: RemoteSharedFileItem) {
        Task {
            if let url = await store.downloadFile(file) {
                downloadedFile = DownloadedRemoteFile(url: url)
            }
        }
    }
}

struct ShareSheetHeader: View {
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 34)).foregroundStyle(BeetTheme.accentBright)
            Text("Move work, not accounts.").font(.title2.weight(.bold)).tracking(-0.3)
            Text("Clipboard and files travel directly between this device and your paired Mac.")
                .font(.subheadline).foregroundStyle(BeetTheme.secondaryText(appearance)).lineSpacing(2)
        }
    }
}

struct ClipboardSharingSection: View {
    let store: RemoteStore
    @Binding var confirmation: String?
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteSectionLabel(title: "CLIPBOARD")
            HStack(spacing: 10) {
                ShareActionButton(title: "Paste from Mac", symbol: "arrow.down.doc", appearance: appearance) {
                    Task {
                        if let text = await store.copyMacClipboard() {
                            UIPasteboard.general.string = text
                            confirmation = text.isEmpty ? "The Mac clipboard is empty." : "Copied the Mac clipboard to this device."
                        }
                    }
                }
                ShareActionButton(title: "Send to Mac", symbol: "arrow.up.doc", appearance: appearance) {
                    let text = UIPasteboard.general.string ?? ""
                    Task {
                        if text.isEmpty { confirmation = "Copy some text on this device first." }
                        else if await store.sendClipboardToMac(text) { confirmation = "Sent this device’s clipboard to your Mac." }
                    }
                }
            }
        }
    }
}

struct ShareActionButton: View {
    let title: String
    let symbol: String
    let appearance: RemoteAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(BeetTheme.accentBright)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading).padding(.horizontal, 13)
            .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.8), lineWidth: 0.75) }
        }
        .buttonStyle(RemotePressButtonStyle())
    }
}

struct FileSharingSection: View {
    let store: RemoteStore
    let onChooseFile: () -> Void
    let onDownload: (RemoteSharedFileItem) -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                RemoteSectionLabel(title: "SHARED FILES")
                Spacer()
                if store.isSharing { ProgressView().controlSize(.small) }
            }
            Button(action: onChooseFile) {
                Label("Send a file to Mac", systemImage: "plus")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(RemoteSecondaryButtonStyle())

            if store.sharedFiles.isEmpty {
                Text("Files shared through Vamp Assistant appear in Downloads › BeetCode Remote on your Mac (legacy storage name).")
                    .font(.subheadline).foregroundStyle(BeetTheme.secondaryText(appearance)).lineSpacing(2).padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.sharedFiles) { file in
                        Button { onDownload(file) } label: { RemoteSharedFileRow(file: file) }
                            .buttonStyle(RemotePressButtonStyle())
                        if file.id != store.sharedFiles.last?.id { Divider().overlay(BeetTheme.line(appearance)).padding(.leading, 48) }
                    }
                }
                .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(BeetTheme.line(appearance).opacity(0.8), lineWidth: 0.75) }
            }
        }
    }
}

struct RemoteSharedFileRow: View {
    let file: RemoteSharedFileItem
    @Environment(\.remoteAppearance) private var appearance
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.fill").foregroundStyle(BeetTheme.accentBright).frame(width: 36, height: 36)
                .background(BeetTheme.surfaceStrong(appearance).opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
            }
            Spacer()
            Image(systemName: "square.and.arrow.down").font(.subheadline.weight(.semibold)).foregroundStyle(BeetTheme.secondaryText(appearance))
        }
        .padding(.horizontal, 11).padding(.vertical, 9).contentShape(Rectangle())
    }
}

struct RemoteSectionLabel: View {
    @Environment(\.remoteAppearance) private var appearance
    let title: String
    var body: some View { Text(title).font(.caption2.weight(.bold)).tracking(0.9).foregroundStyle(BeetTheme.secondaryText(appearance)) }
}

struct DownloadedRemoteFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct RemoteActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
