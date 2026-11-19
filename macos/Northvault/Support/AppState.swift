import Foundation
import Observation
import WalletUI

enum SidebarItem: Hashable {
    case portfolio
    case account(String)
}

enum AccountSection: String, CaseIterable, Identifiable {
    case transactions = "Transactions"
    case send = "Send"
    case receive = "Receive"
    case addresses = "Addresses"
    case utxos = "UTXOs"

    var id: String { rawValue }
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case synced(Date)
    case failed(String)
}

@Observable
final class AppState {
    @ObservationIgnored @MainActor lazy var encryptedWallets = VaultModel()
    static let defaultElectrumURL = "ssl://electrum.blockstream.info:50002"

    static func defaultElectrumURL(for network: Network) -> String {
        network == .bitcoin ? defaultElectrumURL : ""
    }

    /// Bumped whenever wallet data changes, so views that read `wallet` redraw.
    private(set) var revision = 0
    @ObservationIgnored private var service: WalletService
    var wallet: WalletService { _ = revision; return service }
    private(set) var accounts: [Account]

    // Navigation
    var selection: SidebarItem? = .portfolio
    var section: AccountSection = .transactions
    var range: TimeRange = .quarter

    // Settings (persisted)
    var currency: DisplayCurrency { didSet { defaults.set(currency.rawValue, forKey: Keys.currency) } }
    var unit: BitcoinUnit { didSet { defaults.set(unit.rawValue, forKey: Keys.unit) } }
    var hideBalances: Bool { didSet { defaults.set(hideBalances, forKey: Keys.hideBalances) } }
    private(set) var network: Network
    private(set) var electrumURL: String
    private(set) var useSampleData: Bool

    // Status
    var syncStatus: SyncStatus = .idle
    var devices: [HardwareDevice] = []
    var isScanningDevices = false
    /// Shown as an alert by ContentView.
    var alertMessage: String?
    var panelPages: [PanelPage] = []

    // Per-session UI state
    var receiveOffsets: [String: UInt32] = [:]
    var selectedUtxoIDs: Set<Utxo.ID> = []

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let currency = "displayCurrency"
        static let unit = "bitcoinUnit"
        static let hideBalances = "hideBalances"
        static let network = "network"
        static let electrumURL = "electrumURL"
        static let useSampleData = "useSampleData"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.currency = DisplayCurrency(rawValue: defaults.string(forKey: Keys.currency) ?? "") ?? .usd
        self.unit = BitcoinUnit(rawValue: defaults.string(forKey: Keys.unit) ?? "") ?? .btc
        self.hideBalances = defaults.bool(forKey: Keys.hideBalances)
        // Observable properties have accessors; use local values until all
        // stored properties (including the service and accounts) are initialized.
        let network = Network(key: defaults.string(forKey: Keys.network) ?? "") ?? .bitcoin
        let electrumURL = defaults.string(forKey: Keys.electrumURL) ?? Self.defaultElectrumURL(for: network)
        let useSampleData = defaults.bool(forKey: Keys.useSampleData)
        self.network = network
        self.electrumURL = electrumURL
        self.useSampleData = useSampleData
        let (service, error) = Self.makeService(sample: useSampleData, network: network, electrumURL: electrumURL)
        self.service = service
        self.accounts = service.accounts()
        self.alertMessage = error
    }

    /// For SwiftUI previews and integration checks with isolated preferences.
    init(preview wallet: WalletService, defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: "preview") ?? .standard
        self.currency = .usd
        self.unit = .btc
        self.hideBalances = false
        self.network = wallet.network()
        self.electrumURL = ""
        self.useSampleData = wallet.isSample()
        self.service = wallet
        self.accounts = wallet.accounts()
    }

    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Northvault", isDirectory: true)
    }

    private static func makeService(sample: Bool, network: Network, electrumURL: String) -> (WalletService, String?) {
        if sample { return (WalletService.newSample(), nil) }
        do {
            let url = electrumURL.isEmpty ? nil : electrumURL
            return (try WalletService.open(dataDir: dataDirectory.path, network: network, electrumUrl: url), nil)
        } catch {
            return (WalletService.newSample(), "Couldn’t open your wallets, showing sample data instead. \(error.userMessage)")
        }
    }

    var isSample: Bool { wallet.isSample() }

    var needsServer: Bool { !isSample && electrumURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func historyNeedsSync(accountId: String? = nil) -> Bool {
        guard !isSample, !accounts.isEmpty else { return false }
        if case .synced = syncStatus { return false }
        return wallet.transactions(accountId: accountId).isEmpty
    }

    var selectedAccount: Account? {
        guard case .account(let id)? = selection else { return nil }
        return accounts.first { $0.id == id }
    }

    var btcPriceUSD: Double { wallet.btcPriceUsd() }

    var money: MoneyFormat {
        MoneyFormat(
            currency: currency,
            unit: unit,
            hidden: hideBalances,
            usdToCurrency: currency.fiat.map { wallet.fxRateFromUsd(currency: $0) } ?? 1
        )
    }

    func refresh() {
        accounts = wallet.accounts()
        revision += 1
    }

    // MARK: Settings that need the backend reopened

    func update(network: Network? = nil, electrumURL: String? = nil, useSampleData: Bool? = nil) {
        if let electrumURL {
            self.electrumURL = electrumURL.trimmingCharacters(in: .whitespaces)
            defaults.set(self.electrumURL, forKey: Keys.electrumURL)
            try? service.setElectrumServer(url: self.electrumURL.isEmpty ? nil : self.electrumURL)
            syncStatus = .idle
        }
        guard network != nil || useSampleData != nil else { return }
        if let network {
            // An implicit default follows the network; custom addresses stay untouched.
            if defaults.string(forKey: Keys.electrumURL) == nil {
                self.electrumURL = Self.defaultElectrumURL(for: network)
            }
            self.network = network
            defaults.set(network.key, forKey: Keys.network)
        }
        if let useSampleData {
            self.useSampleData = useSampleData
            defaults.set(useSampleData, forKey: Keys.useSampleData)
        }
        let (service, error) = Self.makeService(sample: self.useSampleData, network: self.network, electrumURL: self.electrumURL)
        self.service = service
        selection = .portfolio
        selectedUtxoIDs = []
        syncStatus = .idle
        alertMessage = error
        refresh()
    }

    // MARK: Actions

    /// Runs a throwing call and shows its error as an alert.
    @discardableResult
    func attempt<T>(_ body: () throws -> T) -> T? {
        do { return try body() } catch {
            alertMessage = error.userMessage
            return nil
        }
    }

    @MainActor
    func sync() async {
        guard !isSample, syncStatus != .syncing else { return }
        guard !needsServer else { syncStatus = .idle; return }
        syncStatus = .syncing
        do {
            try await wallet.sync(accountId: nil)
            syncStatus = .synced(Date())
        } catch {
            syncStatus = .failed(error.userMessage)
        }
        refresh()
    }

    @MainActor
    func scanDevices() async {
        guard !isScanningDevices else { return }
        isScanningDevices = true
        defer { isScanningDevices = false }
        do { devices = try await wallet.listDevices() } catch {
            devices = []
            alertMessage = error.userMessage
        }
    }

    /// Connected devices that hold one of this account's keys.
    func signers(for account: Account) -> [HardwareDevice] {
        guard let keystores = try? wallet.walletDetails(accountId: account.id).keystores else { return [] }
        let fingerprints = Set(keystores.map(\.fingerprint))
        return devices.filter { $0.fingerprint.map(fingerprints.contains) ?? false }
    }

    /// Discovery fingerprints are hints: locked devices and a different cached
    /// passphrase wallet must still be selectable. Rust checks the returned address.
    func addressVerificationDevices(for account: Account) -> [HardwareDevice] {
        let matching = Set(signers(for: account).map(\.id))
        return devices.filter { matching.contains($0.id) }
            + devices.filter { !matching.contains($0.id) }
    }
}
