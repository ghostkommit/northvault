import Foundation
import SwiftUI
import WalletModels
import WalletCrypto
import WalletStorage

@MainActor public final class VaultModel: ObservableObject {
    @Published var records: [StoredEnvelope] = []
    @Published var unlocked: [URL: UnlockedWallet] = [:]
    @Published var cached: Set<UUID> = []
    @Published var message: String?
    @Published var storageLabel = "Local encrypted storage"
    @Published var busy = false
    @Published var selected: URL?
    @Published var recoveryHex = ""
    @Published var secretSync = false
    @Published var cacheDEK = true
    @Published var dekSync = false
    @Published var requireAuthentication: Bool {
        didSet { preferences.set(requireAuthentication, forKey: "vault.requireAuthentication"); if requireAuthentication { lock() } }
    }
    @Published var discovery = CloudWalletDiscovery()
    @Published var savedSecrets: [SignerSecretSummary] = []
    private var folders: [ScopedFolder] = []
    private var folderURLs: [URL] = []
    public let locations: WalletLocations
    private var starting = false
    private var refreshing = false
    public var hasDiscoveredWallets: Bool { !records.isEmpty }
    private var local: URL
    private var repository: WalletRepository?
    private var offline: EncryptedOfflineCache?
    private let keychain: any WalletKeychainService
    private let preferences: UserDefaults
    private let coordinator: any FileCoordinating
    private let authenticate: @MainActor () async throws -> Void
    private let cloudDirectory: @MainActor () async -> URL?
    private let refreshInterval: TimeInterval?
    private var observations: [NSObjectProtocol] = []
    private var timer: Timer?
    private var accessCleared = false
    // SECURITY-SENSITIVE: lock invalidates operations that could publish decrypted data after
    // an await, including background recovery and already-started wallet edits.
    private var accessGeneration = UUID()
    private var suppressedWallets: Set<String>
    public convenience init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "WalletKeychainAccessGroup") as? String
        let keychain = AppleWalletKeychain(accessGroup: configured.flatMap { $0.contains("$(") || $0.isEmpty ? nil : $0 })
        self.init(locations: .standard, preferences: .standard, keychain: keychain,
                  coordinator: AppleFileCoordinator(), authenticate: { try await DeviceAuthentication.authorize() },
                  cloudDirectory: {
                      let configured = Bundle.main.object(forInfoDictionaryKey: "WalletUbiquityContainer") as? String
                      guard let container = configured, !container.isEmpty, !container.contains("$(") else { return nil }
                      return await CloudWalletDiscovery.directory(container: container)
                  }, refreshInterval: 15)
    }

    // Internal OS boundaries for isolated integration tests. The public initializer
    // always selects the real Keychain, file coordination and device authentication.
    init(locations: WalletLocations, preferences: UserDefaults, keychain: any WalletKeychainService,
         coordinator: any FileCoordinating, authenticate: @escaping @MainActor () async throws -> Void,
         cloudDirectory: @escaping @MainActor () async -> URL?, refreshInterval: TimeInterval?) {
        self.locations = locations; local = locations.local
        self.preferences = preferences; self.keychain = keychain; self.coordinator = coordinator
        self.authenticate = authenticate; self.cloudDirectory = cloudDirectory; self.refreshInterval = refreshInterval
        requireAuthentication = preferences.bool(forKey: "vault.requireAuthentication")
        suppressedWallets = Set(preferences.stringArray(forKey: "vault.suppressedWallets") ?? [])
        observations.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let owner = self else { return }
            Task { @MainActor in
                owner.lock(); owner.discovery.stop(); owner.repository = nil
                owner.timer?.invalidate(); owner.timer = nil
                owner.records = []; owner.cached = []; owner.selected = nil
                await owner.start()
            }
        })
    }
    public func start() async {
        guard repository == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            offline = try EncryptedOfflineCache(root: local.appendingPathComponent("Offline", isDirectory: true), coordinator: coordinator)
            let directory = await cloudDirectory()
            repository = WalletRepository(files: try EncryptedFileStore(directory: directory ?? local, coordinator: coordinator), keychain: keychain)
            storageLabel = directory == nil ? "Local encrypted storage · iCloud unavailable or not configured" : "iCloud Drive · synchronization is asynchronous"
            if directory != nil { discovery.start() }
            folders = []; folderURLs = []
            for data in preferences.array(forKey: "vault.sharedFolders") as? [Data] ?? [] {
                if let folder = try? ScopedFolder.restore(data) { folders.append(folder); folderURLs.append(folder.url) }
            }
            await refresh()
            if let refreshInterval {
                timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in guard let owner = self else { return }; Task { @MainActor in await owner.refresh() } }
            }
        } catch { message = error.localizedDescription }
    }
    func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        Task { defer { busy = false }; do { try await action() } catch { self.message = error.localizedDescription } }
    }
    func refresh() async {
        guard let repository, !refreshing else { return }
        let generation = accessGeneration
        refreshing = true
        defer { refreshing = false }
        var urls: [URL] = []
        do { urls = try await repository.files.list() }
        catch { message = "Primary storage is unavailable. Checking local encrypted backups." }
        let scan = locations.scan()
        urls += scan.files
        if !scan.inaccessible.isEmpty { message = "A predetermined wallet folder could not be scanned. Other locations are still available. Check folder access in Settings." }
        urls += discovery.urls
        if let offline { urls += (try? await offline.snapshots()) ?? [] }
        for url in discovery.urls where discovery.states[url] == .conflict {
            urls += (try? await repository.files.conflictCopies(url)) ?? []
        }
        for folder in folderURLs { if let store = try? EncryptedFileStore(directory: folder, coordinator: coordinator) { urls += (try? await store.list()) ?? [] } }
        var next: [StoredEnvelope] = []; var keys: Set<UUID> = []
        for url in Set(urls).sorted(by: { $0.path < $1.path }) {
            if url.lastPathComponent.contains(".previous-") { continue }
            if let record = try? await repository.files.read(url) {
                guard generation == accessGeneration else { return }
                next.append(record)
                if unlocked[url]?.stored.digest != record.digest { unlocked[url] = nil }
                if !accessCleared && !requireAuthentication && !suppressedWallets.contains(record.envelope.walletId.uuidString) && unlocked[url] == nil {
                    let wallet = try? await repository.unlock(record)
                    guard generation == accessGeneration else { return }
                    unlocked[url] = wallet
                }
                if (try? await repository.hasCachedDEK(record.envelope)) == true { keys.insert(record.envelope.walletId) }
            } else if discovery.states[url] == .discovering { try? discovery.download(url) }
            else { message = "A wallet file could not be read. It was preserved without replacing any backup." }
        }
        for wallet in unlocked.values {
            do { try await offline?.preserve(wallet) }
            catch { message = "Offline encrypted backup failed: \(error.localizedDescription)" }
        }
        // Keep higher known revisions visible; surface older copies as possible rollback.
        let highest = Dictionary(grouping: next.filter { unlocked[$0.url] != nil }, by: { $0.envelope.walletId }).mapValues { $0.map { $0.envelope.revision }.max() ?? 0 }
        if next.contains(where: { highest[$0.envelope.walletId, default: 0] > $0.envelope.revision && !$0.url.path.contains("/Offline/") }) {
            message = "An older wallet revision was discovered. The newer offline backup is preserved; review related versions."
        }
        guard generation == accessGeneration else { return }
        records = next; cached = keys
        let knownURLs = Set(next.map(\.url))
        unlocked = unlocked.filter { knownURLs.contains($0.key) }
        if selected == nil || !knownURLs.contains(selected!) { selected = visible.first?.url }
        // Do not expose secret bytes to the view; only metadata is displayed.
        let summaries = (try? await repository.secrets.summaries()) ?? []
        guard generation == accessGeneration else { return }
        savedSecrets = summaries
    }
    var visible: [StoredEnvelope] {
        var seen = Set<String>()
        return records.sorted {
            if $0.envelope.walletId == $1.envelope.walletId {
                if (unlocked[$0.url] != nil) != (unlocked[$1.url] != nil) { return unlocked[$0.url] != nil }
                return $0.envelope.revision > $1.envelope.revision
            }
            return $0.envelope.walletId.uuidString < $1.envelope.walletId.uuidString
        }.filter { record in
            let identity = unlocked[record.url]?.payload.descriptors.canonicalIdentity ?? "locked:\(record.envelope.walletId)"
            return seen.insert(identity).inserted
        }
    }
    func relatedRecords(_ record: StoredEnvelope) -> [StoredEnvelope] {
        let identity = unlocked[record.url]?.payload.descriptors.canonicalIdentity
        return records.filter { $0.envelope.walletId == record.envelope.walletId || (identity != nil && unlocked[$0.url]?.payload.descriptors.canonicalIdentity == identity) }
    }
    var current: StoredEnvelope? { records.first { $0.url == selected } }
    func lock() { accessGeneration = UUID(); unlocked = [:]; recoveryHex = ""; accessCleared = true }
    func unlockCurrent() {
        guard let repository, let record = current else { return }
        let generation = accessGeneration
        let hex = recoveryHex; recoveryHex = ""
        perform {
            guard generation == self.accessGeneration else { return }
            if self.requireAuthentication { try await self.authenticate() }
            guard generation == self.accessGeneration else { return }
            let manual = hex.isEmpty ? nil : try BIP85Secret(hex: hex)
            let wallet = try await repository.unlock(record, manual: manual)
            guard generation == self.accessGeneration else { return }
            self.unlocked[record.url] = wallet; self.accessCleared = false
            self.suppressedWallets.remove(record.envelope.walletId.uuidString)
            self.preferences.set(Array(self.suppressedWallets), forKey: "vault.suppressedWallets")
            if let manual {
                for slot in record.envelope.keySlots where (try? EnvelopeCrypto.unwrap(record.envelope, secret: manual, slotId: slot.id)) == wallet.dek {
                    try await repository.secrets.save(SignerAuthorization(fingerprint: slot.fingerprint, index: slot.bip85Index, secret: manual, cosignerIndex: slot.cosignerIndex), mode: self.secretSync ? .synchronized : .local)
                    guard generation == self.accessGeneration else { return }
                }
            }
            if self.cacheDEK { try await repository.cache(wallet, mode: self.dekSync ? .synchronized : .local) }
            guard generation == self.accessGeneration else { return }
            await self.refresh()
        }
    }
    func create(name: String, receive: String, change: String, network: WalletNetwork, hexes: [String], indices: [String]) async throws {
        guard let repository else { throw VaultError.unavailable("Storage is not ready") }
        let generation = accessGeneration
        let d = try DescriptorValidator().validate(receive: receive, change: change.isEmpty ? nil : change, network: network)
        var auths: [SignerAuthorization] = []
        for i in d.cosigners.indices where i < hexes.count && !hexes[i].isEmpty {
            guard indices.indices.contains(i) else { throw VaultError.invalid("Supply a BIP-85 index for each recovery secret") }
            guard let index = UInt32(indices[i]), index < 0x80000000 else { throw VaultError.invalid("BIP-85 index must be between 0 and 2147483647") }
            auths.append(SignerAuthorization(fingerprint: d.cosigners[i].fingerprint, index: index, secret: try BIP85Secret(hex: hexes[i]), cosignerIndex: i))
        }
        let wallet = try await repository.create(name: name, descriptors: d, authorizations: auths, secretMode: secretSync ? .synchronized : .local, cacheMode: cacheDEK ? (dekSync ? .synchronized : .local) : nil)
        guard generation == accessGeneration else { return }
        unlocked[wallet.stored.url] = wallet; selected = wallet.stored.url; await refresh()
    }
    func importFile(_ url: URL) async throws {
        guard let repository else { return }
        let scope = ScopedFolder(url: url); defer { withExtendedLifetime(scope) {} }
        let record = try await repository.files.read(url)
        // Locked inbound ciphertext is staged locally; it never overwrites a known wallet.
        let stage = local.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let destination = stage.appendingPathComponent("\(record.envelope.walletId.uuidString)-\(record.envelope.revisionId.uuidString).walletenc")
        let data = try record.envelope.serialized()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else { throw VaultError.conflict }
        } else { try data.write(to: destination, options: .atomic) }
        if !folderURLs.contains(stage) { folderURLs.append(stage) }
        await refresh(); selected = destination
    }
    func publishCurrent() {
        guard let repository, let selected, let wallet = unlocked[selected] else { return }
        let generation = accessGeneration
        perform {
            guard generation == self.accessGeneration else { return }
            let stored = try await repository.imported(wallet.stored, dek: wallet.dek)
            guard generation == self.accessGeneration else { return }
            self.unlocked[stored.stored.url] = stored
            await self.refresh()
            guard generation == self.accessGeneration else { return }
            self.selected = stored.stored.url
        }
    }
    func addFolder(_ url: URL) async throws {
        let folder = ScopedFolder(url: url); let bookmark = try folder.bookmark()
        var stored = preferences.array(forKey: "vault.sharedFolders") as? [Data] ?? []; stored.append(bookmark)
        preferences.set(stored, forKey: "vault.sharedFolders")
        folders.append(folder); folderURLs.append(url); await refresh()
    }
    func exportData() throws -> Data { guard let current else { throw VaultError.missingKey }; return try current.envelope.serialized() }
    func manageSlot(index: Int, hex: String, bipIndex: String, remove: Bool, rotate: Bool) {
        guard let repository, let selected, let wallet = unlocked[selected] else { return }
        let generation = accessGeneration
        perform {
            guard generation == self.accessGeneration else { return }
            guard wallet.payload.descriptors.cosigners.indices.contains(index) else { throw VaultError.invalid("Choose a signer from this wallet") }
            let existing = wallet.stored.envelope.keySlots.first { $0.cosignerIndex == index }
            let updated: UnlockedWallet
            if rotate {
                guard existing != nil else { throw VaultError.missingKey }
                let keep = Set(wallet.stored.envelope.keySlots.map(\.cosignerIndex)).subtracting([index])
                updated = try await repository.rotate(wallet, retaining: keep, supplied: [])
            } else if remove {
                guard let existing else { throw VaultError.missingKey }
                updated = try await repository.changeSlots(wallet, adding: [], removing: [existing.id], secretMode: .local)
            } else {
                guard let number = UInt32(bipIndex), number < 0x80000000 else { throw VaultError.invalid("BIP-85 index must be between 0 and 2147483647") }
                let auth = SignerAuthorization(fingerprint: wallet.payload.descriptors.cosigners[index].fingerprint, index: number, secret: try BIP85Secret(hex: hex), cosignerIndex: index)
                updated = try await repository.changeSlots(wallet, adding: [auth], removing: [], secretMode: self.secretSync ? .synchronized : .local)
            }
            guard generation == self.accessGeneration else { return }
            self.unlocked[selected] = updated
            if self.cacheDEK { try await repository.cache(updated, mode: self.dekSync ? .synchronized : .local) }
            guard generation == self.accessGeneration else { return }
            await self.refresh()
        }
    }
    func clearLocalAccess() {
        guard let repository, let current else { return }
        perform {
            try await repository.clearCache(current.envelope, mode: .local)
            self.suppressedWallets.insert(current.envelope.walletId.uuidString)
            self.preferences.set(Array(self.suppressedWallets), forKey: "vault.suppressedWallets")
            self.lock(); await self.refresh()
        }
    }
    func clearKey(_ mode: KeyStorageMode) {
        guard let repository, let current else { return }
        perform { try await repository.clearCache(current.envelope, mode: mode); self.lock(); await self.refresh() }
    }
    func saveKey(_ mode: KeyStorageMode) {
        guard let repository, let selected, let wallet = unlocked[selected] else { return }
        perform { try await repository.cache(wallet, mode: mode); await self.refresh() }
    }
    func deleteSecret(_ record: SignerSecretSummary, mode: KeyStorageMode) {
        guard let repository else { return }
        perform { try await repository.secrets.delete(record.id, mode: mode); self.lock(); await self.refresh() }
    }
    func moveSecret(_ record: SignerSecretSummary, from: KeyStorageMode) {
        guard let repository else { return }
        perform { try await repository.secrets.move(id: record.id, from: from, to: from == .local ? .synchronized : .local); await self.refresh() }
    }
    deinit { timer?.invalidate(); observations.forEach(NotificationCenter.default.removeObserver) }
}
