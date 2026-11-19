import SwiftUI

private struct UIManifest: Decodable {
    let fundedAccount: String
    let emptyAccount: String
    let balanceSats: UInt64
    let confirmedSats: UInt64
    let pendingSats: UInt64
    let nextAddress: String
}

private struct UIFailure: Error { let message: String }
private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw UIFailure(message: message) }
}

// All settings changes made while rendering stay in memory, including the
// preferences written by AppState's property observers.
private final class UIPreferences: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "northvault.ui.tests." + UUID().uuidString)! }
    override func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}

@main struct WalletUIChecks {
    @MainActor static func main() async {
        do { try await run(); print("Native Regtest wallet UI checks passed") }
        catch { FileHandle.standardError.write(Data("Wallet UI checks failed: \(error)\n".utf8)); exit(1) }
    }

    @MainActor private static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manifest = try JSONDecoder().decode(UIManifest.self, from: Data(contentsOf: root.appendingPathComponent("ui-fixture.json")))
        let wallet = try WalletService.open(dataDir: root.path, network: .regtest, electrumUrl: nil)
        let preferences = UIPreferences()
        let state = AppState(preview: wallet, defaults: preferences)
        try expect(state.network == .regtest && !state.isSample && !state.useSampleData, "fixture must use real Regtest wallet state")
        try expect(wallet.totalBalanceSats() == manifest.balanceSats && wallet.transactions(accountId: manifest.fundedAccount).count == 2,
                   "native UI must read persisted BDK funding through UniFFI")
        state.currency = .btc
        let snapshot = NativeSnapshot(ContentView().environment(state).environment(\.colorScheme, .dark)
            .frame(width: 1440, height: 1100), size: NSSize(width: 1440, height: 1100))
        defer { snapshot.close() }

        let portfolio = try await snapshot.text(named: "wallet-portfolio", in: root)
        try expect(portfolio.contains("total portfolio") && portfolio.contains("1.37500000"), "portfolio must render the persisted total")
        state.selectSidebarItem(.account(manifest.fundedAccount))
        let transactions = try await snapshot.text(named: "wallet-transactions", in: root)
        try expect(transactions.contains("confirmed balance") && transactions.contains("unconfirmed"), "account transaction statistics must render")
        try expect(transactions.contains("1.25000000") && transactions.contains("0.12500000"), "confirmed and pending amounts must agree with persisted observations")
        try expect(transactions.contains("confirmed fixture") && transactions.contains("pending fixture"), "both transaction labels must appear")

        state.hideBalances = true
        let hidden = try await snapshot.text(named: "wallet-hidden", in: root)
        for amount in ["1.37500000", "1.25000000", "0.12500000"] {
            try expect(!hidden.contains(amount), "privacy setting must hide amounts in sidebar, chart, statistics and transaction rows")
        }
        try expect(hidden.contains("confirmed fixture") && preferences.bool(forKey: "hideBalances"), "hiding amounts must preserve history and save the display choice")
        state.hideBalances = false
        state.unit = .sats
        let sats = try await snapshot.text(named: "wallet-sats", in: root)
        // Group separators follow the host locale; preserve the amount/unit pair
        // while allowing commas, periods and whitespace between digit groups.
        let digits = sats.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        try expect(digits.contains("\(manifest.balanceSats)sats"), "satoshi setting must redraw displayed values")
        state.unit = .btc
        // Suppress USB discovery in these synthetic native workflows.
        state.isScanningDevices = true

        state.section = .utxos
        let outputs = try await snapshot.text(named: "wallet-utxos", in: root)
        try expect(outputs.contains("unspent outputs") && outputs.contains("2 outputs") && outputs.contains("select all"), "UTXO screen must render both persisted coins")
        let coins = wallet.utxos(accountId: manifest.fundedAccount)
        state.selectedUtxoIDs = [coins[0].id]
        let selected = try await snapshot.text(named: "wallet-selected-utxo", in: root)
        try expect(selected.contains("1 of 2 selected") && selected.contains("send selected"), "coin selection must redraw count and send action")
        state.section = .send
        let send = try await snapshot.text(named: "wallet-send", in: root)
        try expect(send.contains("send from regtest savings") && send.contains("spending 1 selected coin") && send.contains("summary"), "send screen must retain coin-control selection")
        let formRecipient = try wallet.nextReceiveAddress(accountId: manifest.emptyAccount, offset: 0).address
        try snapshot.replaceText(placeholder: "tb1… / bcrt1… address", with: formRecipient)
        try snapshot.replaceText(placeholder: "sat/vB", with: "2")
        try snapshot.replaceText(placeholder: "0.00000000", with: "100")
        let insufficient = try await snapshot.text(named: "wallet-send-insufficient", in: root)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        try expect(insufficient.contains("more than the spendable balance"),
                   "native send form must expose the real coin-control funds error")
        try snapshot.replaceText(placeholder: "0.00000000", with: "0.10000000")
        try snapshot.replaceText(placeholder: "e.g. Invoice from contractor", with: "Synthetic form payment")
        let preview = try await snapshot.text(named: "wallet-send-preview", in: root)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        try expect(preview.contains("0.10000000") && !preview.contains("more than the spendable balance"),
                   "correcting the amount must produce a real unsigned draft preview")
        try expect(state.panelPages.isEmpty && wallet.transactions(accountId: manifest.fundedAccount).count == 2,
                   "editing a send preview must neither submit a transaction nor open signing automatically")

        state.section = .addresses
        let addresses = try await snapshot.text(named: "wallet-addresses", in: root)
        try expect(addresses.contains("used fixture address") && addresses.contains("unused"), "address table must distinguish used and unused derivations")
        state.section = .receive
        let receive = try await snapshot.text(named: "wallet-receive", in: root)
        try expect(receive.contains("receive to regtest savings") && receive.contains("find devices") && receive.contains("show qr code"), "receive screen must offer address and device discovery")
        func addressReference(_ address: String) -> some View {
            let characters = Array(address)
            let groupedAddress = stride(from: 0, to: characters.count, by: 4)
                .map { String(characters[$0..<min($0 + 4, characters.count)]) }.joined(separator: " ")
            return Button {} label: {
                Text(groupedAddress).font(Theme.mono(16)).lineSpacing(6).fixedSize()
            }.buttonStyle(.plain).environment(\.colorScheme, .dark).background(Theme.surfaceInset)
        }
        let addressRegion = NSRect(x: 350, y: 185, width: 900, height: 60)
        try expect(try await snapshot.contains(addressReference(manifest.nextAddress), in: addressRegion),
                   "receive glyphs must match the complete expected Regtest address")
        let alteredAddress = manifest.nextAddress.replacingOccurrences(of: "bcrt1", with: "bert1")
        try expect(alteredAddress != manifest.nextAddress, "negative glyph reference must differ")
        let alteredMatches = try await snapshot.contains(addressReference(alteredAddress), in: addressRegion)
        try expect(!alteredMatches,
                   "glyph matching must reject the c/e substitution that OCR can miss")
        try expect(try wallet.nextReceiveAddress(accountId: manifest.fundedAccount, offset: 0).address == manifest.nextAddress,
                   "rendering must not advance the receive address")

        state.showWalletDetails(state.selectedAccount!)
        let details = try await snapshot.text(named: "wallet-details", in: root)
        try expect(details.contains("first receive address") && details.contains("output descriptor"), "wallet details must replace the account workspace")
        try expect(!details.contains("find devices") && !details.contains("show qr code"), "covered receive content must not remain visible behind details")
        state.selectSidebarItem(.account(manifest.fundedAccount))
        let returned = try await snapshot.text(named: "wallet-returned", in: root)
        try expect(returned.contains("confirmed balance") && !returned.contains("output descriptor"), "reselecting account must restore transactions")

        state.showRenameAccount(state.selectedAccount!)
        let rename = try await snapshot.text(named: "wallet-rename", in: root)
        try expect(rename.contains("account name") && rename.contains("regtest savings"),
                   "rename panel must show the current name")
        let renameButton = Button("Rename") {}.buttonStyle(.primary)
            .environment(\.colorScheme, .dark).background(Theme.surface)
        try expect(try await snapshot.contains(renameButton, in: NSRect(x: 340, y: 210, width: 200, height: 60)),
                   "rename panel must render its enabled commit action")
        let registryBlocker = root.appendingPathComponent("regtest/wallets.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: registryBlocker, withIntermediateDirectories: false)
        try snapshot.replaceText(at: NSPoint(x: 550, y: 182), with: "Rejected rename")
        try snapshot.click(at: NSPoint(x: 470, y: 240))
        let renameFailure = try await snapshot.text(named: "wallet-rename-failed", in: root)
        try expect(renameFailure.contains("directory") && !state.panelPages.isEmpty,
                   "failed rename must retain the editor and show the write error")
        try expect(try wallet.walletDetails(accountId: manifest.fundedAccount).account.name == "Regtest savings",
                   "failed native rename must not change the live account name")
        try FileManager.default.removeItem(at: registryBlocker)
        state.selectSidebarItem(.account(manifest.fundedAccount))
        state.showRenameAccount(state.selectedAccount!)
        _ = try await snapshot.text(named: "wallet-rename-retry", in: root)
        try snapshot.replaceText(at: NSPoint(x: 550, y: 182), with: "Renamed Regtest savings")
        try snapshot.click(at: NSPoint(x: 470, y: 240))
        let renamed = try await snapshot.text(named: "wallet-renamed", in: root)
        try expect(state.panelPages.isEmpty && renamed.contains("confirmed balance"),
                   "successful native rename must dismiss the editor and restore account history")
        try expect(state.selectedAccount?.name == "Renamed Regtest savings", "rename must refresh the sidebar model")
        let reopened = try WalletService.open(dataDir: root.path, network: .regtest, electrumUrl: nil)
        try expect(try reopened.walletDetails(accountId: manifest.fundedAccount).account.name == "Renamed Regtest savings",
                   "native rename must persist through UniFFI and a separately reopened wallet")
        state.selectSidebarItem(.account(manifest.fundedAccount))
        let recipient = try wallet.nextReceiveAddress(accountId: manifest.emptyAccount, offset: 0).address
        let draft = try wallet.createTransaction(accountId: manifest.fundedAccount, address: recipient,
            amountSats: 10_000_000, satPerVb: 2, selectedUtxos: [coins[0].outPoint], sendMax: false)
        let signingAccount = state.selectedAccount!
        state.presentPanel("Review and sign") {
            SignTransactionSheet(account: signingAccount, draft: draft, label: "Synthetic payment") {
                preconditionFailure("rendering an unsigned draft must never broadcast")
            }
        }
        let signing = try await snapshot.text(named: "wallet-signing", in: root)
        try expect(signing.contains("review and sign") && signing.contains("network fee"),
                   "review must identify the transaction and network fee")
        func amountReference(_ value: String) -> some View {
            Text(value).font(Theme.mono(13)).fixedSize()
                .environment(\.colorScheme, .dark).background(Theme.surface)
        }
        let paymentRegion = NSRect(x: 770, y: 220, width: 130, height: 60)
        try expect(try await snapshot.contains(amountReference("0.10000000 BTC"), in: paymentRegion),
                   "review glyphs must show the exact payment amount")
        let wrongAmountMatches = try await snapshot.contains(amountReference("0.10000001 BTC"), in: paymentRegion)
        try expect(!wrongAmountMatches, "review amount check must reject a one-satoshi substitution")
        let feeBTC = "\(draft.feeSats / 100_000_000)." + String(format: "%08llu", draft.feeSats % 100_000_000)
        let feeText = feeBTC + " BTC · " + String(format: "%.1f", draft.effectiveFeeRate) + " sat/vB"
        try expect(try await snapshot.contains(amountReference(feeText), in: NSRect(x: 650, y: 270, width: 250, height: 30)),
                   "review glyphs must show the actual draft fee and rate")
        // OCR misreads the monospaced slashed zero, so the count is matched by its glyphs.
        let unsigned = Text("0 of 1").font(Theme.mono(13)).foregroundStyle(Theme.textSecondary).fixedSize()
            .environment(\.colorScheme, .dark).background(Theme.ground)
        try expect(try await snapshot.contains(unsigned, in: NSRect(x: 380, y: 310, width: 120, height: 45))
                   && signing.contains("no signing device connected") && signing.contains("save psbt"),
                   "unsigned Regtest draft must require a signature and offer air-gapped signing")
        let signedCount = Text("1 of 1").font(Theme.mono(13)).foregroundStyle(Theme.textSecondary).fixedSize()
            .environment(\.colorScheme, .dark).background(Theme.ground)
        let signedMatches = try await snapshot.contains(signedCount, in: NSRect(x: 380, y: 310, width: 120, height: 45))
        try expect(!signedMatches, "signature count check must reject a signed count")
        try expect(wallet.transactions(accountId: manifest.fundedAccount).count == 2,
                   "reviewing a draft must not add a wallet transaction")
        state.selectSidebarItem(.account(manifest.fundedAccount))

        state.showSettings()
        let settings = try await snapshot.text(named: "wallet-settings", in: root)
        try expect(settings.contains("display currency") && settings.contains("bitcoin unit"), "settings display controls must render")
        state.selectSidebarItem(.account(manifest.emptyAccount))
        let empty = try await snapshot.text(named: "wallet-unsynced", in: root)
        try expect(empty.contains("not synced") && empty.contains("sync required"), "unscanned account must not report a verified zero balance")
        try expect(state.panelPages.isEmpty && state.selectedUtxoIDs == Set([coins[0].id]), "navigation closes settings without silently changing coin selection")
        try await checkAccountSetup(root: root)
        try await checkCredentials(root: root)
        try await checkFileExport(root: root)
        try await checkSettings(wallet: wallet, root: root)
    }

    @MainActor private static func checkAccountSetup(root: URL) async throws {
        let directory = root.appendingPathComponent("native-setup", isDirectory: true)
        let wallet = try WalletService.open(dataDir: directory.path, network: .regtest, electrumUrl: nil)
        let fixtures = try JSONDecoder().decode([String: String].self, from: Data(contentsOf:
            URL(fileURLWithPath: "shared/Tests/WalletStorageTests/Fixtures/descriptors-regtest.json")))
        let imported = try wallet.importWallet(contents: Data(fixtures["multi"]!.utf8), filename: "synthetic.txt")
        for total in [1, 3] {
            let state = AppState(preview: wallet, defaults: UIPreferences())
            state.isScanningDevices = true
            var dismissed = false
            let setup = NativeSnapshot(AddWalletSheet(policy: MultisigPolicy(required: total == 1 ? 1 : 2, total: total)).environment(state)
                .environment(\.dismissPanel, DismissPanelAction { dismissed = true })
                .environment(\.colorScheme, .dark).frame(width: 1100, height: 900)
                .background(Theme.ground), size: NSSize(width: 1100, height: 900))
            defer { setup.close() }
            let policy = try await setup.text(named: "setup-policy-\(total)", in: root)
            try expect(policy.contains(total == 1 ? "single signature" : "multisig") && policy.contains(total == 1 ? "1 of 1" : "2 of 3"),
                       "account setup must render the initial policy and compatible script")
            let name = "Native \(total)-key account"
            try setup.replaceText(at: NSPoint(x: 300, y: 110), with: name)
            try setup.click(at: NSPoint(x: 1020, y: 852))
            let keys = try await setup.text(named: "setup-keys-\(total)", in: root)
            try expect(keys.contains(total == 1 ? "add the key" : "add 3 keys"),
                       "Continue must advance to the selected number of public keys")
            for index in 0..<total {
                let y = CGFloat(149 + index * 72)
                try setup.click(at: NSPoint(x: 1025, y: y))
                try await Task.sleep(nanoseconds: 50_000_000)
                _ = try await setup.text(named: "setup-manual-\(total)-\(index)", in: root)
                let key = imported.keystores[index]
                try setup.replaceText(placeholder: "Fingerprint", with: key.fingerprint)
                try setup.replaceText(placeholder: "Derivation path", with: key.derivationPath)
                if total == 1 {
                    try setup.replaceText(placeholder: "xpub / zpub / Zpub …", with: "invalid synthetic public key")
                    try setup.click(at: NSPoint(x: 1030, y: y + 104))
                    let rejected = try await setup.text(named: "setup-invalid-key", in: root)
                    try expect(rejected.contains("not a valid extended public key") && wallet.accounts().isEmpty,
                               "native key entry must reject malformed public keys without creating an account")
                }
                try setup.replaceText(placeholder: "xpub / zpub / Zpub …", with: key.xpub)
                try setup.click(at: NSPoint(x: 1030, y: y + 104))
                let added = try await setup.text(named: "setup-added-\(total)-\(index)", in: root)
                try expect(added.contains("change"), "valid public-key input must replace the key editor")
            }
            try setup.click(at: NSPoint(x: 1030, y: 852))
            let review = try await setup.text(named: "setup-review-\(total)", in: root)
            try expect(review.contains("first receive addresses") && review.contains("before you receive funds"),
                       "review must show derived addresses and the independent verification reminder")
            try expect(wallet.accounts().allSatisfy { $0.name != name }, "review must not persist an account")
            if total == 1 {
                let blocker = directory.appendingPathComponent("regtest/wallets.tmp", isDirectory: true)
                try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
                try setup.click(at: NSPoint(x: 1010, y: 852))
                let rejected = try await setup.text(named: "setup-create-failed", in: root)
                try expect(rejected.contains("directory") && !dismissed && wallet.accounts().isEmpty,
                           "failed native creation must retain the review and publish no account")
                try FileManager.default.removeItem(at: blocker)
            }
            try setup.click(at: NSPoint(x: 1010, y: 852))
            _ = try await setup.text(named: "setup-created-\(total)", in: root)
            try expect(dismissed && state.selectedAccount?.name == name, "creation must select the account and close the setup")
            let reopened = try WalletService.open(dataDir: directory.path, network: .regtest, electrumUrl: nil)
            guard let account = reopened.accounts().first(where: { $0.name == name }) else {
                throw UIFailure(message: "native account creation did not persist")
            }
            let details = try reopened.walletDetails(accountId: account.id)
            try expect(details.keystores.count == total && account.isMultisig == (total == 3),
                       "native policy must survive persistence and reopen")
            try expect(details.firstReceiveAddress.hasPrefix("bcrt1"), "native account must retain Regtest network")
            let exported = try reopened.exportWallet(accountId: account.id, format: .descriptor)
            let persistedPolicy = try reopened.importWallet(contents: exported, filename: "native-policy.txt")
            try expect(persistedPolicy.threshold == (total == 1 ? 1 : 2) && persistedPolicy.keystores.count == total,
                       "native creation must persist the exact signing threshold")
        }
    }

    @MainActor private static func checkCredentials(root: URL) async throws {
        let reply = PassphraseReply()
        var dismissed = false
        let prompt = NativeSnapshot(TrezorPassphrasePanel(reply: reply)
            .environment(\.dismissPanel, DismissPanelAction { dismissed = true })
            .environment(\.colorScheme, .dark).frame(width: 700, height: 550)
            .background(Theme.ground), size: NSSize(width: 700, height: 550))
        defer { prompt.close() }
        let text = try await prompt.text(named: "credential-passphrase", in: root)
        try expect(text.contains("standard wallet") && text.contains("recovery seed"),
                   "passphrase entry must distinguish standard wallets and warn against seed entry")
        try prompt.replaceText(placeholder: "Existing wallet passphrase", with: String(repeating: "é", count: 26))
        let oversized = try await prompt.text(named: "credential-oversized", in: root)
        try expect(oversized.contains("50 utf-8 bytes") && !dismissed, "passphrase limit must count UTF-8 bytes")
        let synthetic = " synthetic e\u{0301} passphrase "
        try prompt.replaceText(placeholder: "Existing wallet passphrase", with: synthetic)
        try prompt.replaceText(placeholder: "Confirm passphrase", with: synthetic.trimmingCharacters(in: .whitespaces))
        let mismatch = try await prompt.text(named: "credential-mismatch", in: root)
        try expect(mismatch.contains("match exactly") && !dismissed, "passphrase confirmation must preserve surrounding spaces")
        try prompt.replaceText(placeholder: "Confirm passphrase", with: synthetic)
        _ = try await prompt.text(named: "credential-matched", in: root)
        try prompt.click(at: NSPoint(x: 200, y: 437))
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(dismissed, "matching passphrase must complete the panel")
        try expect(reply.wait().map { Array($0.utf8) } == Array(synthetic.utf8),
                   "native passphrase entry must preserve exact Unicode and whitespace")

        for standard in [true, false] {
            let reply = PassphraseReply()
            var closed = false
            let panel = NativeSnapshot(TrezorPassphrasePanel(reply: reply)
                .environment(\.dismissPanel, DismissPanelAction { closed = true })
                .environment(\.colorScheme, .dark).frame(width: 700, height: 550)
                .background(Theme.ground), size: NSSize(width: 700, height: 550))
            defer { panel.close() }
            _ = try await panel.text(named: standard ? "credential-standard" : "credential-cancel", in: root)
            try panel.click(at: NSPoint(x: 65, y: standard ? 215 : 437))
            try await Task.sleep(nanoseconds: 50_000_000)
            try expect(closed, "standard-wallet and cancellation buttons must close the credential panel")
            try expect(reply.wait() == (standard ? "" : nil), "cancellation must remain distinct from an empty passphrase")
        }
        let entry = PinMatrixEntry()
        let pin = NativeSnapshot(PinMatrixOverlay(entry: entry) { _ = entry.finish(submit: $0) }
            .frame(width: 1000, height: 800), size: NSSize(width: 1000, height: 800))
        defer { pin.close() }
        let pinText = try await pin.text(named: "credential-pin", in: root)
        try expect(pinText.contains("unlock your trezor") && pinText.contains("enter pin positions"),
                   "PIN screen must request positions, not display secret digits")
        try pin.click(at: NSPoint(x: 408, y: 358))
        try pin.click(at: NSPoint(x: 500, y: 414))
        let entered = try await pin.text(named: "credential-pin-entered", in: root)
        try expect(entry.positions == "75" && !entered.contains("75"),
                   "native PIN buttons must collect the device's positional order while masking the display")
        try pin.click(at: NSPoint(x: 459, y: 526))
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(entry.positions == "7", "native delete must remove exactly the last position")
        try pin.click(at: NSPoint(x: 551, y: 526))
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(entry.completed && entry.response == "7" && entry.positions.isEmpty,
                   "native unlock must submit once and clear the displayed entry")
        entry.clear()
    }

    @MainActor private static func checkSettings(wallet: WalletService, root: URL) async throws {
        let preferences = UIPreferences()
        let state = AppState(preview: wallet, defaults: preferences)
        state.isScanningDevices = true
        let settings = NativeSnapshot(SettingsView().environment(state)
            .environment(\.colorScheme, .dark).frame(width: 1100, height: 800, alignment: .topLeading)
            .background(Theme.ground), size: NSSize(width: 1100, height: 800))
        defer { settings.close() }
        _ = try await settings.text(named: "settings-display", in: root)
        try settings.clickButton("Privacy")
        let privacy = try await settings.text(named: "settings-privacy", in: root)
        try expect(privacy.contains("hide balances"), "privacy tab must expose the balance setting")
        try settings.clickButton("Hide balances")
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(state.hideBalances && preferences.bool(forKey: "hideBalances"), "privacy toggle must update and persist the display setting")
        try settings.clickButton("Connection")
        let connection = try await settings.text(named: "settings-connection", in: root)
        try expect(connection.contains("electrum server") && (try settings.selectedPopupItem(containing: "Regtest")) == "Regtest",
                   "connection tab must show the wallet's actual network in the native picker")
        try settings.replaceText(placeholder: "ssl://your-server:50002", with: "   ")
        try await Task.sleep(nanoseconds: 50_000_000)
        try settings.click(at: NSPoint(x: 1020, y: 199))
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(state.needsServer && state.electrumURL.isEmpty && state.syncStatus == .idle && preferences.string(forKey: "electrumURL") == "",
                   "clearing the server must stop at the no-server boundary without implicit network access")
        try settings.clickButton("Data")
        let data = try await settings.text(named: "settings-data", in: root)
        try expect(data.contains("read-only demo"), "sample setting must identify its read-only behavior")
        try settings.clickButton("Show sample wallet")
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(state.isSample && state.useSampleData && preferences.bool(forKey: "useSampleData"),
                   "sample setting must switch to the isolated read-only backend")
        // A persisted sample opt-in keeps default construction and network
        // changes away from the user's real wallet directory.
        let restored = AppState(defaults: preferences)
        try expect(restored.isSample && restored.hideBalances, "reopening app settings must retain sample and privacy choices")
        for network in Network.all {
            restored.selection = .account(restored.accounts[0].id)
            restored.selectedUtxoIDs = ["synthetic-selection"]
            restored.update(network: network)
            try expect(restored.network == network && restored.selection == .portfolio && restored.selectedUtxoIDs.isEmpty,
                       "network settings must clear stale account and coin selection")
            try expect(Network(key: preferences.string(forKey: "network")!) == network,
                       "each network must persist with a reversible preference key")
            await restored.sync()
            try expect(restored.syncStatus == .idle && !restored.historyNeedsSync(), "sample settings must never initiate chain synchronization")
        }
        for currency in DisplayCurrency.allCases {
            restored.currency = currency
            for unit in BitcoinUnit.allCases {
                restored.unit = unit
                let masked = restored.money.value(sats: 123_456_789, priceUSD: restored.btcPriceUSD)
                try expect(masked == MoneyFormat.mask, "all currency/unit settings must honor privacy")
                restored.hideBalances = false
                let visible = restored.money.value(sats: 123_456_789, priceUSD: restored.btcPriceUSD)
                try expect(!visible.isEmpty && visible != masked, "currency/unit settings must render the supplied wallet amount")
                try expect(unit.parse(unit.inputString(123_456_789)) == 123_456_789,
                           "editing displayed Bitcoin amounts must retain integer satoshis")
                restored.hideBalances = true
            }
        }
        let failed: WalletDetails? = restored.attempt { try wallet.walletDetails(accountId: "missing-fixture") }
        try expect(failed == nil && restored.alertMessage == WalletError.UnknownAccount.message,
                   "backend errors must reach the app alert through the public service boundary")
    }

    @MainActor private static func checkFileExport(root: URL) async throws {
        let directory = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("fixture.txt")
        try Data("original synthetic export".utf8).write(to: original)
        let folder = directory.appendingPathComponent("subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var dismissed = false
        let browser = NativeSnapshot(FileBrowserPanel(suggestedName: "fixture.txt", data: Data("replacement".utf8),
            directory: directory, onSelect: { _, _ in })
            .environment(\.dismissPanel, DismissPanelAction { dismissed = true })
            .padding(24).environment(\.colorScheme, .dark).frame(width: 900, height: 800)
            .background(Theme.ground), size: NSSize(width: 900, height: 800))
        defer { browser.close() }
        let text = try await browser.text(named: "file-export", in: root)
        try expect(text.contains("choose where to save") && text.contains("fixture.txt"),
                   "export must show the temporary directory and proposed filename")
        try browser.replaceText(placeholder: "Folder path", with: directory.appendingPathComponent("missing").path)
        try browser.clickButton("Go")
        let missing = try await browser.text(named: "file-missing-folder", in: root)
        try expect(missing.contains("existing folder path"), "invalid folder navigation must fail visibly")
        try browser.replaceText(placeholder: "Folder path", with: folder.path)
        try browser.clickButton("Go")
        _ = try await browser.text(named: "file-subfolder", in: root)
        try browser.clickButton("Up")
        _ = try await browser.text(named: "file-parent", in: root)
        try browser.replaceText(placeholder: "File name", with: "../escape.txt")
        try await browser.click(Button("Save") {}.buttonStyle(.primary)
            .environment(\.colorScheme, .dark).background(Theme.ground),
            in: NSRect(x: 780, y: 500, width: 120, height: 280))
        let invalid = try await browser.text(named: "file-invalid-name", in: root)
        try expect(invalid.contains("without folder separators") && !dismissed,
                   "export must reject traversal names and retain the editor")
        try browser.replaceText(placeholder: "File name", with: "subfolder")
        try await browser.click(Button("Save") {}.buttonStyle(.primary)
            .environment(\.colorScheme, .dark).background(Theme.ground),
            in: NSRect(x: 780, y: 500, width: 120, height: 280))
        let collision = try await browser.text(named: "file-folder-collision", in: root)
        try expect(collision.contains("folder already uses that name"), "export must not replace a directory")
        try browser.replaceText(placeholder: "File name", with: "fixture.txt")
        try await browser.click(Button("Save") {}.buttonStyle(.primary)
            .environment(\.colorScheme, .dark).background(Theme.ground),
            in: NSRect(x: 780, y: 500, width: 120, height: 280))
        let confirmation = try await browser.text(named: "file-replace-confirmation", in: root)
        try expect(confirmation.contains("replace this file") && !dismissed,
                   "existing export must require an explicit replacement decision")
        try browser.clickButton("Keep existing file")
        try expect(try Data(contentsOf: original) == Data("original synthetic export".utf8),
                   "keeping an export must preserve its exact bytes")
        try await browser.click(Button("Save") {}.buttonStyle(.primary)
            .environment(\.colorScheme, .dark).background(Theme.ground),
            in: NSRect(x: 780, y: 500, width: 120, height: 280))
        _ = try await browser.text(named: "file-replace-retry", in: root)
        // Off-screen AppKit does not reliably dispatch destructive SwiftUI
        // button activation. Keep replacement completion as manual acceptance;
        // the automated boundary here is consent and preservation before it.
        try expect(try Data(contentsOf: original) == Data("original synthetic export".utf8),
                   "asking again for replacement must not overwrite without consent")

    }
}
