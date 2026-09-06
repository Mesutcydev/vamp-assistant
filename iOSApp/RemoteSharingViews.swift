import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Clipboard and files, both directions, as a grouped list.
///
/// It was three hand-built cards — a hero, a pair of 76pt tiles and a file
/// card at radius 17 — none of which the rest of the app uses any more.
struct RemoteShareSheet: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var showFileImporter = false
    @State private var downloadedFile: DownloadedRemoteFile?
    @State private var confirmation: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RemotePageHero(
                        icon: "arrow.left.arrow.right",
                        title: "Move work, not accounts",
                        subtitle: "Clipboard and files travel straight between this device and your paired Mac.")
                }
                if !store.isConnected {
                    Section { RemoteOfflineRow(store: store) }
                        .remoteListRow()
                }
                clipboardSection
                filesSection
            }
            .scrollContentBackground(.hidden)
            .background { RemoteBackdrop() }
            .navigationTitle("Share with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.loadSharing() }
            .refreshable { await store.loadSharing() }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task {
                    if await store.uploadFile(url) { confirmation = "Sent \(url.lastPathComponent) to your Mac." }
                }
            }
            .sheet(item: $downloadedFile) { item in RemoteActivityView(items: [item.url]) }
            .overlay(alignment: .bottom) {
                if let confirmation {
                    Text(confirmation)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.82), in: Capsule())
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation(.easeOut(duration: 0.18)) { self.confirmation = nil }
                        }
                }
            }
        }
    }

    private var clipboardSection: some View {
        Section {
            Button {
                Task {
                    if let text = await store.copyMacClipboard() {
                        UIPasteboard.general.string = text
                        confirmation = text.isEmpty
                            ? "The Mac clipboard is empty."
                            : "Copied the Mac clipboard to this device."
                    }
                }
            } label: {
                Label("Paste from Mac", systemImage: "arrow.down.doc")
            }
            Button {
                let text = UIPasteboard.general.string ?? ""
                Task {
                    if text.isEmpty { confirmation = "Copy some text on this device first." }
                    else if await store.sendClipboardToMac(text) {
                        confirmation = "Sent this device’s clipboard to your Mac."
                    }
                }
            } label: {
                Label("Send to Mac", systemImage: "arrow.up.doc")
            }
        } header: {
            Text("Clipboard")
        }
        .disabled(!store.isConnected)
        .remoteListRow()
    }

    private var filesSection: some View {
        Section {
            Button {
                showFileImporter = true
            } label: {
                Label("Send a file to Mac", systemImage: "plus")
            }
            .disabled(!store.isConnected)
            ForEach(store.sharedFiles) { file in
                Button { download(file) } label: { RemoteSharedFileRow(file: file) }
                    .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("Shared files")
                Spacer()
                if store.isSharing { ProgressView().controlSize(.small) }
            }
        } footer: {
            if store.sharedFiles.isEmpty {
                Text("Files shared through Vamp Assistant appear in Downloads › BeetCode Remote on your Mac (legacy storage name).")
            }
        }
        .remoteListRow()
    }

    private func download(_ file: RemoteSharedFileItem) {
        Task {
            if let url = await store.downloadFile(file) {
                downloadedFile = DownloadedRemoteFile(url: url)
            }
        }
    }
}

struct RemoteSharedFileRow: View {
    let file: RemoteSharedFileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.body)
                .foregroundStyle(BeetTheme.accentBright)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).foregroundStyle(.primary).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Image(systemName: "square.and.arrow.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Download \(file.name)")
    }
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
