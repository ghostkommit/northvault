import Foundation
import WalletModels
import WalletCrypto
import WalletStorage
@testable import WalletUI
#if os(macOS)
import SwiftUI
import AppKit
#endif

// UserDefaults is an OS boundary: all preference reads/writes stay in memory.
private final class VolatilePreferences: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "northvault.tests." + UUID().uuidString)! }
    override func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func set(_ value: Any?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}

@MainActor private final class AuthenticationFixture {
    var calls = 0
    var failure: VaultError?
    var suspend = false
    var pending: CheckedContinuation<Void, Never>?
    func authorize() async throws {
        calls += 1
        if suspend { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
    }
    func resume() { let continuation = pending; pending = nil; continuation?.resume() }
}

// Suspend only the external Keychain boundary, while repository, AEAD and file
// operations continue to be the production implementations.
private actor SuspendedKeychain: WalletKeychainService {
    enum Operation { case load, save }
    let base: MemoryKeychain
    private var next: Operation?
    private var pending: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { pending != nil }
    init(_ base: MemoryKeychain) { self.base = base }
    func suspendNext(_ operation: Operation) { next = operation }
    func resume() { let continuation = pending; pending = nil; continuation?.resume() }
    private func suspendIfNeeded(_ operation: Operation) async {
        guard next == operation else { return }
        next = nil
        await withCheckedContinuation { pending = $0 }
    }
    func save(_ data: Data, id: String, mode: KeyStorageMode) async throws {
        await suspendIfNeeded(.save)
        try await base.save(data, id: id, mode: mode)
    }
    func load(id: String, mode: KeyStorageMode) async throws -> Data? {
        await suspendIfNeeded(.load)
        return try await base.load(id: id, mode: mode)
    }
    func delete(id: String, mode: KeyStorageMode) async throws { try await base.delete(id: id, mode: mode) }
    func records(prefix: String) async throws -> [(String, Data, KeyStorageMode)] { try await base.records(prefix: prefix) }
}

@MainActor private final class VaultFixture {
    let root: URL
    let locations: WalletLocations
    let preferences = VolatilePreferences()
    let keychain = MemoryKeychain()
    let authentication = AuthenticationFixture()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("northvault-vault-model-" + UUID().uuidString)
        locations = WalletLocations(applicationSupport: root.appendingPathComponent("support"), documents: root.appendingPathComponent("documents"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func model(keychain override: (any WalletKeychainService)? = nil) -> VaultModel {
        VaultModel(locations: locations, preferences: preferences, keychain: override ?? keychain,
                   coordinator: TestFileCoordinator(), authenticate: { try await self.authentication.authorize() },
                   cloudDirectory: { nil }, refreshInterval: nil)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor private func waitFor(_ message: String, _ predicate: () async -> Bool) async throws {
    let deadline = Date(timeIntervalSinceNow: 10)
    while !(await predicate()) {
        if Date() >= deadline { throw CheckFailure(message: message + ": timed out") }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor private func finish(_ model: VaultModel) async throws {
    try await waitFor("vault action completion") { !model.busy }
}

@MainActor private func create(_ model: VaultModel, descriptor: String, signers: Int = 1) async throws {
    try await model.create(name: "Regtest UI fixture", receive: descriptor, change: "", network: .regtest,
                           hexes: (0..<signers).map { String(repeating: String(format: "%02x", $0 + 31), count: 32) },
                           indices: Array(repeating: "0", count: signers))
    try require(model.current != nil && model.unlocked[model.current!.url] != nil, "created vault is selected and authenticated")
}

@MainActor func runVaultModelChecks(fixtures: [String: String]) async throws -> Int {
    try await checkVaultLockAndRecovery(fixtures["multi"]!)
    try await checkVaultSlotActions(fixtures["multi"]!)
    try await checkVaultImportPublish(fixtures["multi"]!)
    try await checkVaultRefreshRecovery(fixtures["multi"]!)
    try await checkVaultLockDuringAuthentication(fixtures["multi"]!)
    try await checkVaultLockDuringRecovery(fixtures["multi"]!)
    try await checkVaultLockDuringWrites(fixtures["multi"]!)
    try await checkVaultLockBeforeQueuedActions(fixtures["multi"]!)
    try await checkVaultInvalidSlotActions(fixtures["multi"]!)
    try await checkVaultCreationBoundaries(fixtures["multi"]!)
    try await checkVaultStorageFailures(fixtures["multi"]!)
    #if os(macOS)
    // OCR of rendered controls needs Retina text; hosted 1x CI displays opt out
    // and report one check fewer rather than a pass.
    if ProcessInfo.processInfo.environment["NORTHVAULT_SKIP_RENDERED_UI"] == "1" { return 11 }
    try await checkVaultRenderedPrivacy(fixtures["multi"]!)
    return 12
    #else
    return 11
    #endif
}

@MainActor private func checkVaultLockAndRecovery(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let model = fixture.model()
    do { _ = try model.exportData(); throw CheckFailure(message: "empty vault export succeeded") } catch VaultError.missingKey {}
    await model.start(); await model.start() // Idempotent startup, no background timer in tests.
    try require(!model.hasDiscoveredWallets && model.visible.isEmpty, "fresh Regtest vault starts empty")
    try await create(model, descriptor: descriptor)
    let record = model.current!
    try require(model.hasDiscoveredWallets && model.visible.count == 1 && model.cached.contains(record.envelope.walletId), "creation updates discovery and cached-key UI")
    let exported = try WalletEnvelope.read(model.exportData())
    try require(exported == record.envelope, "vault export is the selected encrypted envelope")
    model.lock(); await model.refresh()
    try require(model.unlocked.isEmpty, "refresh must not undo explicit lock")
    model.recoveryHex = String(repeating: "ff", count: 32)
    model.unlockCurrent(); try await finish(model)
    try require(model.unlocked.isEmpty && model.recoveryHex.isEmpty && model.message != nil, "wrong recovery secret fails and clears entry")
    model.recoveryHex = String(repeating: "1f", count: 32)
    model.unlockCurrent(); try await finish(model)
    try require(model.unlocked[record.url] != nil && model.message == nil, "valid manual recovery unlocks")
    model.saveKey(.synchronized); try await finish(model)
    model.clearKey(.local); try await finish(model)
    try require(model.unlocked.isEmpty, "clearing a DEK locks visible payloads")
    model.unlockCurrent(); try await finish(model)
    try require(model.unlocked[record.url] != nil, "retained synchronized key recovers")
    model.clearLocalAccess(); try await finish(model)
    try require(model.unlocked.isEmpty, "clear local access locks all payloads")
    try require(fixture.preferences.stringArray(forKey: "vault.suppressedWallets") == [record.envelope.walletId.uuidString], "automatic recovery suppression is persisted")
    let restarted = fixture.model(); await restarted.start()
    try require(restarted.unlocked.isEmpty && restarted.hasDiscoveredWallets, "restart preserves explicit suppression")
    restarted.selected = record.url
    restarted.unlockCurrent(); try await finish(restarted)
    try require(restarted.unlocked[record.url] != nil, "explicit unlock can clear suppression")
    try require(fixture.preferences.stringArray(forKey: "vault.suppressedWallets") == [], "explicit unlock clears persisted suppression")
    restarted.requireAuthentication = true
    fixture.authentication.failure = .authentication
    restarted.unlockCurrent(); try await finish(restarted)
    try require(restarted.unlocked.isEmpty && fixture.authentication.calls == 1, "authentication refusal cannot reveal payload")
    fixture.authentication.failure = nil
    restarted.unlockCurrent(); try await finish(restarted)
    try require(restarted.unlocked[record.url] != nil && fixture.authentication.calls == 2, "device authentication precedes successful unlock")
    let summary = restarted.savedSecrets.first!
    restarted.moveSecret(summary, from: summary.mode); try await finish(restarted)
    try require(restarted.savedSecrets.contains { $0.id == summary.id && $0.mode != summary.mode }, "secret move updates displayed storage mode")
    restarted.deleteSecret(restarted.savedSecrets.first!, mode: restarted.savedSecrets.first!.mode); try await finish(restarted)
    try require(restarted.unlocked.isEmpty && restarted.savedSecrets.isEmpty, "deleting recovery secret locks and updates summaries")
}

@MainActor private func checkVaultSlotActions(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let model = fixture.model(); await model.start()
    try await create(model, descriptor: descriptor, signers: 2)
    let original = model.unlocked[model.current!.url]!
    model.secretSync = true
    model.manageSlot(index: 2, hex: String(repeating: "21", count: 32), bipIndex: "0", remove: false, rotate: false)
    try await finish(model)
    try require(model.current!.envelope.keySlots.count == 3 && model.message == nil, "adding third recovery slot updates current envelope")
    model.manageSlot(index: 2, hex: String(repeating: "21", count: 32), bipIndex: "invalid", remove: false, rotate: false)
    try await finish(model)
    try require(model.current!.envelope.keySlots.count == 3 && model.message != nil, "invalid BIP85 index preserves slots")
    model.manageSlot(index: 0, hex: "", bipIndex: "", remove: false, rotate: true)
    try await finish(model)
    let rotated = model.unlocked[model.current!.url]!
    try require(rotated.stored.envelope.keySlots.count == 2 && rotated.dek != original.dek, "rotation revokes old DEK while keeping selected recovery signers")
    model.manageSlot(index: 2, hex: "", bipIndex: "", remove: true, rotate: false)
    try await finish(model)
    try require(model.current!.envelope.keySlots.count == 1, "slot removal retains remaining signer")
    let before = model.current!.digest
    model.manageSlot(index: 1, hex: "", bipIndex: "", remove: true, rotate: false)
    try await finish(model)
    try require(model.current!.digest == before && model.message != nil, "cannot remove last recovery signer")
    model.manageSlot(index: 0, hex: "", bipIndex: "", remove: true, rotate: false)
    try await finish(model)
    try require(model.message != nil && model.current!.digest == before, "removing absent slot fails without mutation")
}

@MainActor private func checkVaultImportPublish(_ descriptor: String) async throws {
    let sourceFixture = try VaultFixture(); defer { sourceFixture.cleanup() }
    let source = sourceFixture.model(); await source.start(); try await create(source, descriptor: descriptor)
    let bytes = try source.exportData()
    let destinationFixture = try VaultFixture(); defer { destinationFixture.cleanup() }
    let model = destinationFixture.model(); await model.start()
    let input = destinationFixture.root.appendingPathComponent("import.walletenc")
    try bytes.write(to: input)
    try await model.importFile(input)
    let staged = model.current!
    try require(staged.url.path.contains("/Inbox/") && model.unlocked.isEmpty, "encrypted imports stage without automatic disclosure")
    try await model.importFile(input)
    try require(model.visible.count == 1, "repeated encrypted import is idempotent")
    model.recoveryHex = String(repeating: "1f", count: 32)
    model.unlockCurrent(); try await finish(model)
    try require(model.unlocked[staged.url]?.payload.descriptors.network == .regtest, "staged Regtest wallet recovers")
    model.publishCurrent(); try await finish(model)
    try require(model.current!.url.deletingLastPathComponent() == destinationFixture.locations.local, "publishing writes to primary encrypted storage")
    try require(model.visible.count == 1 && model.relatedRecords(model.current!).count >= 2, "equivalent staged and primary copies grouped without deletion")
    var tampered = try WalletEnvelope.read(bytes); tampered.payload[0] ^= 1
    try tampered.serialized().write(to: input)
    do { try await model.importFile(input); throw CheckFailure(message: "same-version conflicting import replaced staged copy") } catch VaultError.conflict {}
    try require(try Data(contentsOf: staged.url) == bytes, "conflicting import preserves original ciphertext")
}

@MainActor private func checkVaultRefreshRecovery(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let model = fixture.model(); await model.start(); try await create(model, descriptor: descriptor)
    let original = model.current!
    model.manageSlot(index: 1, hex: String(repeating: "20", count: 32), bipIndex: "0", remove: false, rotate: false)
    try await finish(model)
    try require(model.current!.envelope.revision > original.envelope.revision, "slot update creates a newer known revision")
    try original.envelope.serialized().write(to: original.url)
    await model.refresh()
    try require(model.message?.contains("older wallet revision") == true, "known rollback is surfaced without deleting history")
    try Data("corrupt fixture".utf8).write(to: original.url)
    await model.refresh()
    try require(model.records.allSatisfy { $0.url != original.url } && model.unlocked[original.url] == nil, "corrupt replacement removes stale displayed plaintext")
    try require(model.hasDiscoveredWallets && model.visible.count == 1, "offline backup remains discoverable after primary corruption")
    try require(try Data(contentsOf: original.url) == Data("corrupt fixture".utf8), "corrupt file remains preserved for review")
}

@MainActor private func checkVaultLockDuringAuthentication(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let model = fixture.model(); await model.start(); try await create(model, descriptor: descriptor)
    model.requireAuthentication = true
    fixture.authentication.suspend = true
    model.unlockCurrent()
    try await waitFor("authentication prompt started") { fixture.authentication.pending != nil }
    // Backgrounding invokes lock even while the authentication action is busy.
    model.lock()
    fixture.authentication.resume()
    try await finish(model)
    try require(model.unlocked.isEmpty, "late authentication completion must not undo a newer lock")
    try require(model.recoveryHex.isEmpty, "cancelled authentication retains no recovery entry")
    fixture.authentication.suspend = false
    model.unlockCurrent(); try await finish(model)
    try require(!model.unlocked.isEmpty, "a fresh unlock after cancelling old authentication still succeeds")
}

@MainActor private func checkVaultLockDuringRecovery(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let source = fixture.model(); await source.start(); try await create(source, descriptor: descriptor)
    let keychain = SuspendedKeychain(fixture.keychain)
    let model = fixture.model(keychain: keychain)
    await keychain.suspendNext(.load)
    let starting = Task { await model.start() }
    try await waitFor("automatic recovery reading cached DEK") { await keychain.isWaiting }
    model.lock()
    await keychain.resume(); await starting.value
    await model.refresh()
    try require(model.unlocked.isEmpty && model.hasDiscoveredWallets, "lock during automatic recovery preserves locked discovery")

    model.selected = source.current!.url
    await keychain.suspendNext(.load)
    model.unlockCurrent()
    try await waitFor("manual unlock reading cached DEK") { await keychain.isWaiting }
    model.lock()
    await keychain.resume(); try await finish(model)
    try require(model.unlocked.isEmpty, "late repository unlock cannot publish after lock")
    model.unlockCurrent(); try await finish(model)
    try require(model.unlocked[model.current!.url] != nil, "explicit recovery works after a cancelled cached-key read")
}

@MainActor private func checkVaultLockDuringWrites(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let keychain = SuspendedKeychain(fixture.keychain)
    let model = fixture.model(keychain: keychain); await model.start()
    await keychain.suspendNext(.save)
    let creation = Task {
        try await model.create(name: "Interrupted Regtest creation", receive: descriptor, change: "", network: .regtest,
                               hexes: [String(repeating: "1f", count: 32)], indices: ["0"])
    }
    try await waitFor("creation saving recovery material") { await keychain.isWaiting }
    model.lock()
    await keychain.resume(); try await creation.value
    await model.refresh()
    try require(model.unlocked.isEmpty && model.hasDiscoveredWallets, "completed creation after lock retains ciphertext without revealing payload")
    model.unlockCurrent(); try await finish(model)
    let previous = model.current!
    await keychain.suspendNext(.save)
    model.manageSlot(index: 1, hex: String(repeating: "20", count: 32), bipIndex: "0", remove: false, rotate: false)
    try await waitFor("slot edit saving recovery material") { await keychain.isWaiting }
    model.lock()
    await keychain.resume(); try await finish(model)
    await model.refresh()
    try require(model.unlocked.isEmpty, "completed slot edit cannot reveal wallet after lock")
    try require(model.current!.envelope.revision > previous.envelope.revision, "already-started encrypted edit remains discoverable")
    model.unlockCurrent(); try await finish(model)
    try require(model.unlocked[model.current!.url] != nil, "completed edit remains recoverable after cancellation")
}

@MainActor private func checkVaultLockBeforeQueuedActions(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let model = fixture.model(); await model.start(); try await create(model, descriptor: descriptor)
    let original = model.current!
    model.publishCurrent(); model.lock(); try await finish(model)
    try require(model.unlocked.isEmpty, "lock invalidates queued publish before repository access")
    model.unlockCurrent(); model.lock(); try await finish(model)
    try require(model.unlocked.isEmpty, "lock invalidates queued unlock before repository access")
    model.unlockCurrent(); try await finish(model)
    model.manageSlot(index: 1, hex: String(repeating: "20", count: 32), bipIndex: "0", remove: false, rotate: false)
    model.lock(); try await finish(model)
    try require(model.unlocked.isEmpty, "lock invalidates queued slot edit")
    await model.refresh()
    try require(model.current!.digest == original.digest, "cancelled queued mutation preserves envelope")
}

@MainActor private func checkVaultInvalidSlotActions(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let model = fixture.model(); await model.start(); try await create(model, descriptor: descriptor)
    let original = model.current!
    let keychainBefore = await fixture.keychain.values
    // A signer picker can retain an index after switching to a wallet with fewer
    // cosigners. Every action must reject it before indexing or rotating keys.
    for index in [3, -1, Int.max] {
        for action in [(false, true), (true, false), (false, false)] {
            model.manageSlot(index: index, hex: String(repeating: "20", count: 32), bipIndex: "0", remove: action.0, rotate: action.1)
            try await finish(model)
            try require(model.message != nil && model.current!.digest == original.digest,
                        "invalid signer selection must not rotate or alter the wallet")
            try require(try Data(contentsOf: original.url) == original.envelope.serialized(), "invalid signer action preserves stored ciphertext")
        }
    }
    // A valid cosigner without a recovery slot also cannot be removed/rotated.
    model.manageSlot(index: 1, hex: "", bipIndex: "", remove: true, rotate: true)
    try await finish(model)
    try require(model.message != nil && model.current!.digest == original.digest, "cannot rotate away an absent recovery signer")
    for indexText in ["-1", "2147483648", "4294967296", "", "one"] {
        model.manageSlot(index: 1, hex: String(repeating: "20", count: 32), bipIndex: indexText, remove: false, rotate: false)
        try await finish(model)
        try require(model.message != nil && model.current!.digest == original.digest, "invalid BIP85 index cannot create a recovery slot")
    }
    try require(await fixture.keychain.values == keychainBefore, "rejected slot actions must not persist recovery material")
    model.manageSlot(index: 1, hex: String(repeating: "20", count: 32), bipIndex: "2147483647", remove: false, rotate: false)
    try await finish(model)
    try require(model.message == nil && model.current!.envelope.keySlots.contains { $0.bip85Index == 2147483647 }, "maximum nonhardened BIP85 index is accepted")
}

@MainActor private func checkVaultCreationBoundaries(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let model = fixture.model()
    let secret = String(repeating: "1f", count: 32)
    do {
        try await model.create(name: "Regtest", receive: descriptor, change: "", network: .regtest, hexes: [secret], indices: ["0"])
        throw CheckFailure(message: "creation before storage startup succeeded")
    } catch VaultError.unavailable {}
    await model.start()
    for (hexes, indices) in [([secret], []), ([secret], ["invalid"]), ([secret], ["2147483648"]), (["bad hex"], ["0"]), ([], [])] {
        do {
            try await model.create(name: "Regtest", receive: descriptor, change: "", network: .regtest, hexes: hexes, indices: indices)
            throw CheckFailure(message: "invalid recovery input accepted")
        } catch VaultError.invalid {}
        try require(model.records.isEmpty && model.unlocked.isEmpty && model.selected == nil, "failed creation leaves no wallet selected or revealed")
        try require(await fixture.keychain.values.isEmpty, "failed creation must not store recovery material")
    }
    do {
        try await model.create(name: "  ", receive: descriptor, change: "", network: .regtest, hexes: [secret], indices: ["0"])
        throw CheckFailure(message: "blank name accepted")
    } catch VaultError.invalid {}
    let validated = try DescriptorValidator().validate(receive: descriptor, change: nil, network: .regtest)
    model.cacheDEK = false; model.secretSync = true
    try await model.create(name: " Regtest separate branches ", receive: validated.receive, change: validated.change,
                           network: .regtest, hexes: [secret], indices: ["0"])
    try require(model.current != nil && model.cached.isEmpty, "creation without DEK caching still succeeds")
    try require(model.unlocked[model.current!.url]?.payload.name == "Regtest separate branches", "creation trims the display name")
    try require(model.savedSecrets.count == 1 && model.savedSecrets[0].mode == .synchronized, "secret sync consent is applied independently of DEK caching")
    model.lock(); model.unlockCurrent(); try await finish(model)
    try require(!model.unlocked.isEmpty && model.cached.isEmpty, "recovery through saved signer secret does not silently enable DEK caching")
}

#if os(macOS)
@MainActor private func checkVaultRenderedPrivacy(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    let model = fixture.model(); await model.start(); try await create(model, descriptor: descriptor)
    let snapshot = NativeSnapshot(EncryptedWalletsView(model: model)
        .frame(width: 820).environment(\.colorScheme, .light).background(Color.white))
    defer { snapshot.close() }

    let unlockedText = try await snapshot.text(named: "vault-unlocked", in: fixture.root)
    try require(unlockedText.contains("regtest ui fixture") && unlockedText.contains("2-of-3"), "rendered unlocked view must show authenticated name and signing policy")
    try require(!unlockedText.contains("unlock wallet"), "unlocked view must not show the recovery form")
    model.lock()
    let lockedText = try await snapshot.text(named: "vault-locked", in: fixture.root)
    try require(lockedText.contains("locked wallet") && lockedText.contains("unlock wallet"), "rendered locked view must offer recovery")
    try require(!lockedText.contains("regtest ui fixture") && !lockedText.contains("2-of-3"), "locking must remove decrypted wallet name and policy from rendered content")
    model.unlockCurrent(); try await finish(model)
    let recoveredText = try await snapshot.text(named: "vault-recovered", in: fixture.root)
    try require(recoveredText.contains("regtest ui fixture") && !recoveredText.contains("unlock wallet"), "rendered wallet returns after authenticated recovery")

    try snapshot.clickButton("Reveal descriptors")
    let revealed = try await snapshot.text(named: "vault-revealed", in: fixture.root)
    try require(revealed.contains("hide descriptors") && revealed.contains("validated change"),
                "explicit reveal must show branch details and the hide action")
    try snapshot.clickButton("Hide descriptors")
    let concealed = try await snapshot.text(named: "vault-concealed", in: fixture.root)
    try require(!concealed.contains("validated change"), "hiding descriptors must remove the revealed content")

    let creationFixture = try VaultFixture(); defer { creationFixture.cleanup() }
    let creationModel = creationFixture.model(); await creationModel.start()
    let form = NativeSnapshot(EncryptedWalletsView(model: creationModel, initialDescriptor: descriptor, name: "Native encrypted fixture")
        .frame(width: 820, height: 1200, alignment: .topLeading)
        .environment(\.colorScheme, .light).background(Color.white), size: NSSize(width: 820, height: 1200))
    defer { form.close() }
    let initial = try await form.text(named: "vault-import-form", in: creationFixture.root)
    try require(initial.contains("import and protect") && initial.contains("native encrypted fixture"),
                "backup form must initialize the authenticated name and descriptor")
    try form.clickButton("Validate descriptors")
    try await Task.sleep(nanoseconds: 50_000_000)
    try require(creationModel.message != nil, "Regtest descriptor must fail under the default mainnet selection")
    try form.choosePopupItem("regtest")
    try await Task.sleep(nanoseconds: 50_000_000)
    try form.clickButton("Validate descriptors")
    let validated = try await form.text(named: "vault-import-validated", in: creationFixture.root)
    try require(creationModel.message == nil && validated.contains("2-of-3") && validated.contains("recovery slot"),
                "explicit network selection must validate and expose the actual cosigner policy")
    try form.replaceText(placeholder: "BIP-85 HEX (optional for this signer)", occurrence: 0, with: "invalid synthetic secret")
    try form.click(at: NSPoint(x: 31, y: 1061))
    try await Task.sleep(nanoseconds: 50_000_000)
    let count = Set(creationModel.records.map { $0.envelope.walletId }).count
    try form.clickButton("Encrypt and save")
    try await finish(creationModel)
    let rejected = try await form.text(named: "vault-import-rejected", in: creationFixture.root)
    try require(creationModel.message != nil && Set(creationModel.records.map { $0.envelope.walletId }).count == count && rejected.contains("import and protect"),
                "invalid recovery material must keep the form open without persisting a wallet")
    try form.replaceText(placeholder: "BIP-85 HEX (optional for this signer)", occurrence: 0,
                         with: String(repeating: "42", count: 32))
    try await Task.sleep(nanoseconds: 50_000_000)
    try form.clickButton("Encrypt and save")
    try await finish(creationModel)
    let saved = try await form.text(named: "vault-import-saved", in: creationFixture.root)
    try require(Set(creationModel.records.map { $0.envelope.walletId }).count == count + 1 && !saved.contains("import and protect"),
                "successful native encrypted import must persist and dismiss the form")
    creationModel.lock(); creationModel.unlockCurrent(); try await finish(creationModel)
    try require(creationModel.unlocked[creationModel.current!.url]?.payload.name == "Native encrypted fixture",
                "native creation must recover through the encrypted repository and isolated Keychain")
}
#endif

@MainActor private func checkVaultStorageFailures(_ descriptor: String) async throws {
    let fixture = try VaultFixture(); defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.locations.local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("blocked storage fixture".utf8).write(to: fixture.locations.local)
    let model = fixture.model(); await model.start()
    try require(model.message != nil && !model.hasDiscoveredWallets, "startup storage failure is reported")
    try FileManager.default.removeItem(at: fixture.locations.local)
    await model.start(); try await create(model, descriptor: descriptor)
    let original = model.current!
    await fixture.keychain.failDelete(in: .local)
    model.clearLocalAccess(); try await finish(model)
    try require(model.message != nil && fixture.preferences.stringArray(forKey: "vault.suppressedWallets") == nil,
                "failed key deletion cannot claim that local access was cleared")
    await fixture.keychain.failDelete(in: nil)
    let before = await fixture.keychain.values
    await fixture.keychain.failSave(in: .synchronized)
    model.saveKey(.synchronized); try await finish(model)
    let after = await fixture.keychain.values
    try require(model.message != nil && before == after, "failed key sync preserves existing key material")
    await fixture.keychain.failSave(in: nil)
    model.saveKey(.synchronized); try await finish(model)
    model.clearKey(.local); try await finish(model)
    model.unlockCurrent(); try await finish(model)
    try require(model.unlocked[original.url] != nil, "key sync recovers after earlier save failure")

    try FileManager.default.createDirectory(at: fixture.locations.documents.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("blocked documents fixture".utf8).write(to: fixture.locations.documents)
    await model.refresh()
    try require(model.message?.contains("predetermined wallet folder") == true && model.unlocked[original.url] != nil,
                "inaccessible discovery location does not hide wallets in other locations")
    let snapshots = try FileManager.default.contentsOfDirectory(at: fixture.locations.offline, includingPropertiesForKeys: nil)
    let snapshot = snapshots.first { $0.pathExtension == "walletenc" }!
    let invalid = Data("corrupt offline snapshot fixture".utf8)
    try invalid.write(to: snapshot)
    await model.refresh()
    try require(model.message?.contains("Offline encrypted backup failed") == true, "offline preservation failure is reported")
    try require(try Data(contentsOf: snapshot) == invalid && model.unlocked[original.url] != nil,
                "corrupt snapshot is preserved while authenticated primary wallet remains accessible")
}
