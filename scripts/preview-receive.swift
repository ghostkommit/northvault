import SwiftUI
import AppKit

// Isolated UI integration fixture: real ReceiveView/UniFFI sample data, no wallet
// files, discovery, Keychain, networking, or hardware calls. Device buttons are disabled.
@main
struct ReceivePreviewApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var state: AppState = {
        let state = AppState(preview: WalletService.newSample())
        state.isScanningDevices = true // Disable real USB discovery in this fixture.
        return state
    }()
    @State private var wide = true
    @State private var deviceCount = 0
    @State private var copyResult = ""

    var body: some Scene {
        WindowGroup("Receive UI checks") {
            VStack(spacing: 0) {
                HStack {
                    Toggle("Wide layout", isOn: $wide)
                    Picker("Devices", selection: $deviceCount) {
                        Text("None").tag(0)
                        Text("One").tag(1)
                        Text("Three").tag(3)
                    }.pickerStyle(.segmented).frame(width: 200)
                    Button("Check copied address") {
                        let account = state.accounts[0]
                        let info = try? state.wallet.nextReceiveAddress(accountId: account.id, offset: state.receiveOffsets[account.id] ?? 0)
                        copyResult = info != nil && NSPasteboard.general.string(forType: .string) == info?.address
                            ? "Exact address copied" : "Clipboard does not match"
                    }
                    Text(copyResult)
                    Button("Account panel checks") { openWindow(id: "account-panels") }
                }.padding()
                ReceiveView(account: state.accounts[0])
                    .environment(state)
            }
            .frame(width: wide ? 1200 : 760, height: 780)
            .background(Theme.ground)
            .preferredColorScheme(.dark)
            .onChange(of: deviceCount) { _, count in
                state.devices = Array([
                    HardwareDevice(id: "fixture:trezor", kind: .trezor, model: "Trezor", fingerprint: nil),
                    HardwareDevice(id: "fixture:jade", kind: .jade, model: "Jade", fingerprint: nil),
                    HardwareDevice(id: "fixture:coldcard", kind: .coldcard, model: "Coldcard", fingerprint: nil)
                ].prefix(count))
            }
        }
        .windowResizability(.contentSize)

        WindowGroup("Account UI checks", id: "account-panels") {
            AccountPanelPreview()
        }
        .windowToolbarStyle(.unified)
    }
}

// Uses a temporary synthetic wallet so the real account menu, file panels, and
// sidebar can be exercised without opening the user's wallet or starting sync.
@MainActor
private struct AccountPanelPreview: View {
    @State private var state: AppState?
    @State private var directory: URL?
    @State private var error: String?
    @State private var pinResult = ""

    var body: some View {
        Group {
            if let state {
                ContentView().environment(state)
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Button("Test PIN overlay") {
                                pinResult = TrezorPinHandler.showMatrix() == nil ? "PIN cancelled" : "Synthetic PIN submitted"
                            }
                            Button("Test PIN timeout") {
                                pinResult = TrezorPinHandler.showMatrix(timeout: 3) == nil ? "PIN timed out" : "Synthetic PIN submitted"
                            }
                            Text(pinResult)
                        }.padding()
                    }
            } else {
                Text(error ?? "Preparing synthetic wallet…")
            }
        }
        .frame(minWidth: 1100, minHeight: 780)
        .preferredColorScheme(.dark)
        .task {
            guard state == nil else { return }
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                self.directory = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let wallet = try WalletService.open(dataDir: directory.path, network: .bitcoin, electrumUrl: nil)
                let url = Bundle.main.url(forResource: "descriptors", withExtension: "json")!
                let fixtures = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
                var config = try wallet.importWallet(contents: Data(fixtures["multi"]!.utf8), filename: "fixture.txt")
                config.name = "Preview wallet"
                let account = try wallet.createWallet(config: config)
                let state = AppState(preview: wallet)
                state.isScanningDevices = true
                state.syncStatus = .syncing
                state.selectSidebarItem(.account(account.id))
                state.showAddWallet()
                self.state = state
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear {
            state = nil
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
