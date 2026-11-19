import SwiftUI

@main
struct NorthvaultApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 780)
                .task {
                    await state.encryptedWallets.start()

                }
                .task {
                    setTrezorPinProvider(provider: TrezorPinHandler(state: state))
                    await state.sync()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { state.showSettings() }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("Add Account…") { state.showAddWallet() }
                    .keyboardShortcut("n")
                    .disabled(state.isSample)
                Button("Sync Now") { Task { await state.sync() } }
                    .keyboardShortcut("r")
                    .disabled(state.isSample)
            }
        }

    }
}
