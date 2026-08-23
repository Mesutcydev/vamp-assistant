import SwiftUI

@main
struct BeetCodeRemoteApp: App {
    @State private var store = RemoteStore()

    var body: some Scene {
        WindowGroup {
            RemoteRootView(store: store)
                .tint(BeetTheme.accent)
                .task { await store.restore() }
        }
    }
}

enum BeetTheme {
    static let accent = Color(red: 0.48, green: 0.12, blue: 0.24)
    static let accentBright = Color(red: 0.82, green: 0.28, blue: 0.46)
    static let wash = Color(red: 0.48, green: 0.12, blue: 0.24).opacity(0.1)
}
