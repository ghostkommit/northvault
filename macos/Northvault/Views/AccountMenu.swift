import SwiftUI
import WalletUI

/// Toolbar menu for the selected account: details, export, labels, device registration.
@MainActor
struct AccountMenu: View {
    @Environment(AppState.self) private var state
    let account: Account
    var body: some View {
        Menu {
            Button("Wallet Details…") { state.showWalletDetails(account) }

            Menu("Export") {
                ForEach(formats, id: \.self) { format in
                    Button(format.title) { state.showAccountExport(account, format: format) }
                }
            }
            Button("Import Labels (BIP329)…") { state.showImportLabels(account) }

            if account.isMultisig {
                Button("Register on Device…") {
                    state.presentAccountPanel("Register on device") { RegisterWalletPanel(account: account) }
                }
            }

            Divider()
            Button("Rename…") { state.showRenameAccount(account) }
            Button("Remove from This Mac…", role: .destructive) {
                state.presentAccountPanel("Remove account") {
                    PanelConfirmation(
                        message: "Remove “\(account.name)” from this Mac? Only the watch-only copy is removed. Your funds stay on your keys, and you can import the wallet again.",
                        actionTitle: "Remove", destructive: true) {
                        try state.wallet.deleteWallet(accountId: account.id)
                        state.selectSidebarItem(.portfolio)
                        state.refresh()
                    }
                }
            }
        } label: {
            Label("Account", systemImage: "ellipsis.circle")
        }
        .help("Account actions")
    }

    private var formats: [ExportFormat] {
        account.isMultisig ? [.descriptor, .coldcardMultisig, .bsms, .specterDiy, .labels] : [.descriptor, .labels]
    }

}

@MainActor
extension AppState {
    func showWalletDetails(_ account: Account) {
        presentAccountPanel("Wallet details") { WalletDetailsSheet(account: account) }
    }

    func showAccountExport(_ account: Account, format: ExportFormat) {
        attempt {
            let data = try wallet.exportWallet(accountId: account.id, format: format)
            let base = account.name.replacingOccurrences(of: "/", with: "-")
            presentAccountPanel("Export \(format.title)") {
                FileBrowserPanel(suggestedName: "\(base) \(format.fileName)", data: data, onSelect: { _, _ in })
            }
        }
    }

    func showImportLabels(_ account: Account) {
        presentAccountPanel("Import labels (BIP329)") {
            FileBrowserPanel(suggestedName: nil, data: nil) { data, _ in
                let count = try self.wallet.importLabels(accountId: account.id, contents: data)
                self.refresh()
                self.alertMessage = "Imported \(count) labels."
            }
        }
    }

    func showRenameAccount(_ account: Account) {
        presentAccountPanel("Rename account") {
            PanelTextEditor(initial: account.name, fieldLabel: "Account name", actionTitle: "Rename") { name in
                try self.wallet.renameWallet(accountId: account.id, name: name)
                self.refresh()
            }
        }
    }
}

@MainActor
private struct RegisterWalletPanel: View {
    @Environment(AppState.self) private var state
    let account: Account
    @State private var registering: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(account.name).font(.headline)
            Text("Register this multisig wallet so your device can verify receive and change addresses.")
                .foregroundStyle(Theme.textMuted)
            let devices = state.signers(for: account)
            if devices.isEmpty {
                Text("Connect a cosigner device, then find devices.").foregroundStyle(Theme.textMuted)
            }
            ForEach(devices) { device in
                Button(registering == device.id ? "Confirm on \(device.model)…" : "Register on \(device.model)") {
                    register(on: device)
                }.buttonStyle(.secondary).disabled(registering != nil)
            }
            Button("Find devices") { Task { await state.scanDevices() } }
                .buttonStyle(.secondary).disabled(state.isScanningDevices || registering != nil)
        }
    }

    private func register(on device: HardwareDevice) {
        registering = device.id
        Task { @MainActor in
            defer { registering = nil }
            do {
                try await state.wallet.deviceRegisterWallet(deviceId: device.id, accountId: account.id)
                state.alertMessage = "\(device.model): wallet registered."
            } catch {
                state.alertMessage = error.userMessage
            }
        }
    }
}

/// Keys and descriptor of an account, for checking against devices and other wallets.
struct WalletDetailsSheet: View {
    @Environment(AppState.self) private var state
    let account: Account

    var body: some View {
        let details = try? state.wallet.walletDetails(accountId: account.id)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(account.name).font(.system(size: 16, weight: .semibold))
            Text("\(account.policy) · \(account.scriptType.title) · \(account.standard)")
                .foregroundStyle(Theme.textMuted)

            if let details {
                KeystoreList(keystores: details.keystores)
                InfoTile(label: "First receive address", value: details.firstReceiveAddress, mono: true)
                InfoTile(label: "Output descriptor", value: details.descriptor, mono: true)
            }
        }
    }
}

struct KeystoreList: View {
    let keystores: [Keystore]

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(Array(keystores.enumerated()), id: \.offset) { _, k in
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: "key").foregroundStyle(Theme.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(k.label).fontWeight(.semibold)
                            Text(k.fingerprint).font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                            Text(k.derivationPath).font(Theme.mono(12)).foregroundStyle(Theme.textMuted)
                        }
                        Text(k.xpub).font(Theme.mono(11)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.m)
                .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
        }
    }
}
