import SwiftUI
import WalletUI

/// Settings use the same card surface as Net Worth, with account-style section tabs.
@MainActor
struct SettingsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case display = "Display", connection = "Connection", wallets = "Encrypted wallets"
        case privacy = "Privacy", data = "Data"
        var id: String { rawValue }
    }
    @Environment(AppState.self) private var state
    @State private var section: Section = .display
    @State private var serverDraft = ""
    @State private var backupDescriptor: String?
    @State private var backupName = "Wallet"
    @State private var backupSession = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            Picker("Settings section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .card()
        .padding(Theme.Space.xxl)
        .frame(maxWidth: 1240, alignment: .leading)
        .onAppear { serverDraft = state.electrumURL }
        .onChange(of: state.electrumURL) { _, value in serverDraft = value }
    }

    @ViewBuilder private var content: some View {
        @Bindable var state = state
        switch section {
        case .display:
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Picker("Display currency", selection: $state.currency) {
                    ForEach(DisplayCurrency.allCases) { Text("\($0.rawValue) — \($0.name)").tag($0) }
                }.pickerStyle(.radioGroup)
                Picker("Bitcoin unit", selection: $state.unit) {
                    ForEach(BitcoinUnit.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                note("Used for the net worth chart, balances and transaction values.")
            }
        case .connection:
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Picker("Network", selection: Binding(get: { state.network }, set: { state.update(network: $0) })) {
                    ForEach(Network.all, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Electrum server").font(.headline)
                HStack {
                    TextField("ssl://your-server:50002", text: $serverDraft)
                        .font(Theme.mono(12)).field().onSubmit { save() }
                    Button("Save") { save() }.buttonStyle(.primary)
                        .disabled(serverDraft == state.electrumURL)
                }
                note("Mainnet defaults to Blockstream’s public Electrum server. You can use your own Electrum, electrs or Fulcrum server. A public server learns your addresses and balances. Each network keeps its own wallets.")
            }
        case .wallets:
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if !state.accounts.isEmpty && !state.isSample {
                    Menu("Create encrypted backup of account") {
                        ForEach(state.accounts) { account in
                            Button(account.name) {
                                state.attempt {
                                    backupDescriptor = try state.wallet.walletDetails(accountId: account.id).descriptor
                                    backupName = account.name
                                    backupSession = UUID()
                                }
                            }
                        }
                    }.buttonStyle(.secondary)
                    note("Creates an encrypted copy. Your existing local wallet database remains unchanged.")
                }
                EncryptedWalletsView(model: state.encryptedWallets, initialDescriptor: backupDescriptor, name: backupName)
                    .id(backupSession)
            }
        case .privacy:
            Toggle("Hide balances", isOn: $state.hideBalances)
        case .data:
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Toggle("Show sample wallet", isOn: Binding(get: { state.useSampleData }, set: { state.update(useSampleData: $0) }))
                LabeledContent("Price source", value: "Sample rates. Connect an approved price feed")
                note("The sample wallet is read-only demo data for design review.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        state.update(electrumURL: serverDraft)
        Task { await state.sync() }
    }
}
