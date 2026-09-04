import SwiftUI

struct RemoteDiagnosticsView: View {
    let store: RemoteStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: store.isConnected ? "Connected" : "Disconnected")
                    LabeledContent("Mac version", value: store.hostStatus?.appVersion ?? "Not reported")
                    LabeledContent("Mac build", value: store.hostStatus?.appBuild ?? "Not reported")
                    LabeledContent("Protocol", value: store.hostStatus?.protocolVersion.map(String.init) ?? "Legacy")
                    if let last = store.lastConnectedAt {
                        LabeledContent("Last connected") { Text(last, style: .relative) }
                    }
                    Button("Check connection") { Task { await store.connectSaved() } }
                        .disabled(store.isConnecting || !store.hasSavedConnection)
                }
                Section {
                    ShareLink(item: store.connectionDiagnostics) {
                        Label("Share diagnostics", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("The report excludes addresses, access tokens, computer names, files, and conversation text.")
                }
            }
            .navigationTitle("Connection details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
