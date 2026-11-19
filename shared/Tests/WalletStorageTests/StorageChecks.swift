import Foundation
import CryptoKit
import WalletModels
import WalletCrypto
import WalletStorage

struct CheckFailure: Error { let message: String }
func require(_ value: Bool, _ message: String) throws { if !value { throw CheckFailure(message: message) } }
func rejects(_ message: String, _ work: () throws -> Void) throws { do { try work() } catch { return }; throw CheckFailure(message: message) }
// Controlled file coordination for deterministic tests; production always uses NSFileCoordinator.
struct TestFileCoordinator: FileCoordinating {
    func coordinate<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T { try body(url) }
}
actor MemoryKeychain: WalletKeychainService {
    var values: [String: Data] = [:]
    var failure: Int32?
    var saveFailureMode: KeyStorageMode?
    var deleteFailureMode: KeyStorageMode?
    func setFailure(_ value: Int32?) { failure = value }
    func failSave(in mode: KeyStorageMode?) { saveFailureMode = mode }
    func failDelete(in mode: KeyStorageMode?) { deleteFailureMode = mode }
    func save(_ data: Data, id: String, mode: KeyStorageMode) throws { if let failure { throw VaultError.keychain(failure) }; if saveFailureMode == mode { throw VaultError.keychain(-34018) }; values[mode.rawValue + ":" + id] = data }
    func load(id: String, mode: KeyStorageMode) throws -> Data? { if let failure { throw VaultError.keychain(failure) }; return values[mode.rawValue + ":" + id] }
    func delete(id: String, mode: KeyStorageMode) throws { if let failure { throw VaultError.keychain(failure) }; if deleteFailureMode == mode { throw VaultError.keychain(-34018) }; values.removeValue(forKey: mode.rawValue + ":" + id) }
    func records(prefix: String) throws -> [(String, Data, KeyStorageMode)] {
        if let failure { throw VaultError.keychain(failure) }
        return values.compactMap { key,data in let parts = key.split(separator: ":", maxSplits: 1).map(String.init); guard parts[1].hasPrefix(prefix) else { return nil }; return (parts[1], data, KeyStorageMode(rawValue: parts[0])!) }
    }
}
func runStorageChecks(fixture: URL) async throws -> Int {
    let fixtures = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: fixture))
    let validator = DescriptorValidator()
    func validate(_ key: String) throws -> ValidatedDescriptors { try validator.validate(receive: fixtures[key]!, change: nil, network: .regtest) }
    let d = try validate("multi")
    try require(d.threshold == 2 && d.cosigners.count == 3, "2-of-3 metadata")
    try require(d.receive.contains("/0/*") && d.change.contains("/1/*"), "branch preservation")
    let pair = try validator.validate(receive: d.receive, change: d.change, network: .regtest)
    try require(pair.sourceReceive == d.receive && pair.sourceChange == d.change && pair.canonicalIdentity == d.canonicalIdentity, "separate descriptor fidelity")
    try require(try validate("reordered").canonicalIdentity == d.canonicalIdentity, "sortedmulti deduplication")
    try require(try validate("ordered").canonicalIdentity != validate("orderedReversed").canonicalIdentity, "multi key order")
    try rejects("bad checksum") { _ = try validator.validate(receive: fixtures["multi"]! + "#deadbeef", change: nil, network: .regtest) }
    try rejects("bad network") { _ = try validator.validate(receive: fixtures["multi"]!, change: nil, network: .mainnet) }
    try rejects("private key") { _ = try validator.validate(receive: "tprv-not-permitted", change: nil, network: .regtest) }
    let auths = try d.cosigners.enumerated().map { i,c in SignerAuthorization(fingerprint: c.fingerprint, secret: try BIP85Secret(data: Data(repeating: UInt8(i+1), count:32)), cosignerIndex:i) }
    let payload = WalletPayload(name:"Synthetic test vault", descriptors:d)
    let (e,key) = try EnvelopeCrypto.create(payload, authorizations:auths)
    try require(e.keySlots.count == 3 && key.count == 32, "three independent slots")
    for i in 0..<3 {
        let recovered = try EnvelopeCrypto.unwrap(e, secret:auths[i].secret, slotId:e.keySlots[i].id)
        try require(recovered == key && EnvelopeCrypto.decrypt(e,dek:recovered) == payload, "independent recovery")
    }
    let kekA = EnvelopeCrypto.kek(secret: auths[0].secret, envelope:e,slot:e.keySlots[0]).withUnsafeBytes { Data($0) }
    let kekAgain = EnvelopeCrypto.kek(secret: auths[0].secret, envelope:e,slot:e.keySlots[0]).withUnsafeBytes { Data($0) }
    var sameSaltSlot = e.keySlots[1]; sameSaltSlot.hkdfSalt = e.keySlots[0].hkdfSalt
    let kekB = EnvelopeCrypto.kek(secret: auths[0].secret, envelope:e,slot:sameSaltSlot).withUnsafeBytes { Data($0) }
    try require(kekA == kekAgain && kekA != kekB, "deterministic, slot-separated HKDF")
    try rejects("wrong secret") { _ = try EnvelopeCrypto.unwrap(e,secret:auths[1].secret,slotId:e.keySlots[0].id) }
    try rejects("wrong DEK") { _ = try EnvelopeCrypto.decrypt(e,dek:Data(repeating:9,count:32)) }
    var tampered = e; tampered.payload[20] ^= 1
    try rejects("ciphertext authentication") { _ = try EnvelopeCrypto.decrypt(tampered,dek:key) }
    tampered = e; tampered.revision += 1
    try rejects("revision authentication") { _ = try EnvelopeCrypto.decrypt(tampered,dek:key) }
    tampered = e; tampered.walletId = UUID()
    try rejects("wallet binding") { _ = try EnvelopeCrypto.unwrap(tampered,secret:auths[0].secret,slotId:e.keySlots[0].id) }
    tampered = e; tampered.keySlots[0].fingerprint = "00000000"
    try rejects("fingerprint authentication") { _ = try EnvelopeCrypto.unwrap(tampered,secret:auths[0].secret,slotId:e.keySlots[0].id) }
    tampered = e; tampered.keySlots.removeLast()
    try rejects("slot manifest authentication") { _ = try EnvelopeCrypto.decrypt(tampered,dek:key) }
    tampered = e; tampered.formatVersion = 2
    try rejects("future version") { _ = try tampered.serialized() }
    let serialized = try e.serialized()
    try require(try WalletEnvelope.read(serialized) == e, "serialization")
    let publicText = String(decoding: serialized,as:UTF8.self)
    try require(!publicText.contains(payload.name) && !publicText.contains(d.cosigners[0].xpub) && !publicText.contains("sourceReceive"), "no public wallet contents")
    let changed = try EnvelopeCrypto.editSlots(e,dek:key)
    try require(changed.payload.prefix(12) != e.payload.prefix(12), "fresh payload nonce")
    let (rotated,newKey) = try EnvelopeCrypto.rotate(e,dek:key,retaining:Array(auths.dropFirst()))
    try require(newKey != key, "fresh rotated DEK")
    try rejects("old key on new file") { _ = try EnvelopeCrypto.decrypt(rotated,dek:key) }
    for slot in rotated.keySlots { try rejects("removed signer after rotation") { _ = try EnvelopeCrypto.unwrap(rotated,secret:auths[0].secret,slotId:slot.id) } }
    let restored = try EnvelopeCrypto.unwrap(rotated,secret:auths[1].secret,slotId:rotated.keySlots[0].id)
    try require(restored == newKey, "retained recovery after rotation")
    let single = try validate("single")
    let singlePayload = WalletPayload(name:"Single",descriptors:single)
    let (singleE,singleKey) = try EnvelopeCrypto.create(singlePayload,authorizations:[auths[0]])
    try require(singleKey != key && singlePayload.walletId != payload.walletId, "independent single and multi keys")
    try require(try EnvelopeCrypto.unwrap(singleE,secret:auths[0].secret,slotId:singleE.keySlots[0].id) == singleKey, "same signer recovers single")
    try rejects("malformed HEX") { _ = try BIP85Secret(hex:"seed words are never accepted") }
    try require(try BIP85Secret(hex:String(repeating:"aB",count:32)).keychainData() == Data(repeating:0xab,count:32), "canonical HEX")
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let files = try EncryptedFileStore(directory:root, coordinator:TestFileCoordinator())
    let saved = try await files.save(e,dek:key)
    let idempotent = try await files.save(e,dek:key)
    try require(saved.digest == idempotent.digest, "same UUID import")
    let next = try await files.save(changed,expected:saved,dek:key)
    do { _ = try await files.save(try EnvelopeCrypto.editSlots(e,dek:key),expected:saved,dek:key); throw CheckFailure(message:"stale writer accepted") } catch VaultError.conflict {}
    try require(try await files.read(saved.url).digest == next.digest, "conflict preserves valid current file")
    do { _ = try await files.save(tampered,expected:next,dek:key); throw CheckFailure(message:"corrupt save accepted") } catch is VaultError {}
    try require(try await files.read(saved.url).digest == next.digest, "corrupt save preserves backup")
    let blank = MemoryKeychain()
    let freshRepository = WalletRepository(files: files, keychain: blank)
    let reused = try await freshRepository.create(name: "Repeated import", descriptors: d, authorizations: auths, secretMode: .local, cacheMode: nil)
    try require(reused.payload.walletId == payload.walletId, "provided secret deduplicates existing locked wallet")
    let memory = MemoryKeychain()
    let repository = WalletRepository(files:files,keychain:memory)
    let recovered = try await repository.unlock(next,manual:auths[0].secret)
    try await repository.cache(recovered,mode:.local)
    try require(try await repository.unlock(next).payload.walletId == payload.walletId, "local key unlock")
    try await repository.moveCache(recovered,from:.local,to:.synchronized)
    try require(try await memory.load(id:WalletRepository.keyID(e),mode:.local) == nil, "mode switch removes local copy")
    try await repository.clearCache(e,mode:.synchronized)
    do { _ = try await repository.unlock(next); throw CheckFailure(message:"missing key accepted") } catch VaultError.missingKey {}
    try await repository.secrets.save(auths[0],mode:.synchronized)
    try require(try await repository.unlock(next).dek == key, "BIP85 keychain recovery without DEK")
    let singleStored = try await files.save(singleE,dek:singleKey)
    try require(try await repository.unlock(singleStored).dek == singleKey, "cached signer independently recovers both accounts")
    await memory.setFailure(-34018)
    do { _ = try await repository.unlock(next); throw CheckFailure(message:"entitlement failure hidden") } catch VaultError.keychain(-34018) {}
    await memory.setFailure(nil)
    let duplicate = WalletPayload(name:"Duplicate",descriptors:try validate("reordered"))
    let (dupeEnvelope,dupeKey) = try EnvelopeCrypto.create(duplicate,authorizations:[SignerAuthorization(fingerprint:duplicate.descriptors.cosigners[0].fingerprint,secret:auths[2].secret,cosignerIndex:0)])
    let dupe = try await files.save(dupeEnvelope,dek:dupeKey)
    let groups = WalletRepository.duplicateGroups([recovered,UnlockedWallet(stored:dupe,payload:duplicate,dek:dupeKey),UnlockedWallet(stored:singleStored,payload:singlePayload,dek:singleKey)])
    try require(groups.count == 2 && groups.contains(where:{$0.count == 2}), "private duplicate grouping; single and multi distinct")
    let offline = try EncryptedOfflineCache(root: root.appendingPathComponent("offline"), coordinator: TestFileCoordinator())
    try await offline.preserve(recovered)
    let offlineURLs = try await offline.snapshots()
    try require(offlineURLs.count == 1, "offline cache discovery")
    let offlineRecord = try await files.read(offlineURLs[0])
    try require(try await repository.unlock(offlineRecord, manual: auths[0].secret).payload == recovered.payload, "offline independent recovery")
    let locations = WalletLocations(applicationSupport: root.appendingPathComponent("support"), documents: root.appendingPathComponent("documents"))
    try require(locations.scan().files.isEmpty && !FileManager.default.fileExists(atPath: locations.local.path), "startup scan tolerates missing folders without creating them")
    for folder in locations.directories { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let automatic = locations.documents.appendingPathComponent("automatic.walletenc")
    try e.serialized().write(to: automatic)
    try e.serialized().write(to: locations.inbox.appendingPathComponent("incoming.walletenc"))
    try e.serialized().write(to: locations.local.appendingPathComponent("ignored.previous-old.walletenc"))
    try Data("ignored".utf8).write(to: locations.local.appendingPathComponent("plain.txt"))
    try FileManager.default.createSymbolicLink(at: locations.local.appendingPathComponent("link.walletenc"), withDestinationURL: automatic)
    try FileManager.default.createDirectory(at: locations.local.appendingPathComponent("directory.walletenc"), withIntermediateDirectories: true)
    let discovered = locations.scan()
    try require(discovered.files.count == 2 && discovered.inaccessible.isEmpty, "fixed locations discover envelopes only, excluding backups, symlinks and directories")
    try require(locations.scan().files == discovered.files, "repeated discovery is stable without duplicate imports")
    let autoRecord = try await files.read(automatic)
    try require(try await repository.unlock(autoRecord).payload == payload, "discovered wallet automatically recovers with cached signer secret")
    return 45 + (try await runRecoveryChecks(fixtures: fixtures)) + (try await runKeychainAdapterChecks(fixtures: fixtures)) + (try await runVaultModelChecks(fixtures: fixtures))
}
