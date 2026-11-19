import Foundation
import Security
import WalletModels
import WalletCrypto
@testable import WalletStorage

// Emulates only the four Security.framework operations. The production adapter,
// secret store, encrypted repository, CryptoKit and descriptor bridge all run.
// No SecItem function is called by this fixture.
private final class SecurityItemFixture: @unchecked Sendable {
    enum Operation: Equatable { case update, add, copy, delete }
    private let lock = NSLock()
    private let expectedGroup: String?
    private var items: [String: [String: Any]] = [:]
    private var pending: [(Operation, OSStatus, CFTypeRef?)] = []
    private var calls: [Operation] = []
    private var violations: [String] = []

    init(group: String? = nil) { expectedGroup = group }
    var operations: SecurityItemOperations {
        SecurityItemOperations(
            update: { self.perform(.update, $0, attributes: $1).0 },
            add: { self.perform(.add, $0).0 },
            copy: { self.perform(.copy, $0) },
            delete: { self.perform(.delete, $0).0 }
        )
    }

    func respond(_ operation: Operation, status: OSStatus, result: CFTypeRef? = nil) {
        lock.lock(); defer { lock.unlock() }
        pending.append((operation, status, result))
    }
    func clearCalls() { lock.lock(); defer { lock.unlock() }; calls = [] }
    func callSequence() -> [Operation] { lock.lock(); defer { lock.unlock() }; return calls }
    func checkQueries() throws {
        lock.lock(); defer { lock.unlock() }
        try require(violations.isEmpty, "Security.framework query contract: " + violations.joined(separator: ", "))
        try require(pending.isEmpty, "every injected Security.framework response was exercised")
    }

    private func perform(_ operation: Operation, _ input: CFDictionary, attributes: CFDictionary? = nil) -> (OSStatus, CFTypeRef?) {
        lock.lock(); defer { lock.unlock() }
        let query = input as! [String: Any]
        let account = query[kSecAttrAccount as String] as? String
        let synchronized = query[kSecAttrSynchronizable as String] as? Bool
        func expect(_ condition: Bool, _ message: String) { if !condition { violations.append(message) } }
        expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String, "generic password class")
        expect(query[kSecAttrService as String] as? String == "northvault.wallet-storage.v1", "service namespace")
        expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true, "Data Protection Keychain required")
        expect(query[kSecAttrAccessGroup as String] as? String == expectedGroup, "access group preserved")
        expect(query[kSecAttrSynchronizable as String] != nil, "sync scope explicit")
        calls.append(operation)

        if operation == .update || operation == .add {
            let values = attributes.map { $0 as! [String: Any] } ?? query
            expect(account != nil && synchronized != nil, "writes target one account and mode")
            expect(values[kSecValueData as String] is Data, "writes contain bytes")
            let accessibility = synchronized == true ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            expect(values[kSecAttrAccessible as String] as? String == accessibility as String, "accessibility matches sync mode")
        }
        if operation == .copy {
            expect(query[kSecReturnData as String] as? Bool == true, "reads request data")
            if account == nil {
                expect(query[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String, "enumeration includes both modes")
                expect(query[kSecReturnAttributes as String] as? Bool == true, "enumeration requests metadata")
                expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String, "enumeration requests all records")
            } else {
                expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String, "lookup requests one record")
            }
        }
        if let next = pending.first, next.0 == operation {
            pending.removeFirst()
            return (next.1, next.2)
        }
        let key = account.map { "\($0):\(synchronized == true)" }
        switch operation {
        case .update:
            guard let key, var stored = items[key] else { return (errSecItemNotFound, nil) }
            stored.merge(attributes! as! [String: Any]) { _, new in new }
            items[key] = stored
            return (errSecSuccess, nil)
        case .add:
            guard let key else { return (errSecParam, nil) }
            guard items[key] == nil else { return (errSecDuplicateItem, nil) }
            items[key] = query
            return (errSecSuccess, nil)
        case .delete:
            guard let key, items.removeValue(forKey: key) != nil else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, nil)
        case .copy:
            if let key {
                guard let item = items[key] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, item[kSecValueData as String] as AnyObject?)
            }
            guard !items.isEmpty else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, Array(items.values) as NSArray)
        }
    }
}

private func expectKeychainStatus(_ status: OSStatus, _ message: String, _ action: () async throws -> Void) async throws {
    do { try await action() }
    catch let error as VaultError {
        try require(error == .keychain(status), message + ": incorrect status")
        return
    }
    throw CheckFailure(message: message + ": unexpectedly succeeded")
}

func runKeychainAdapterChecks(fixtures: [String: String]) async throws -> Int {
    let descriptors = try DescriptorValidator().validate(receive: fixtures["multi"]!, change: nil, network: .regtest)
    let auth = SignerAuthorization(fingerprint: descriptors.cosigners[0].fingerprint,
        secret: try BIP85Secret(data: Data(repeating: 29, count: 32)), cosignerIndex: 0)
    try await checkRepositoryThroughAppleAdapter(descriptors, auth)
    try await checkAdapterErrorPropagation()
    try await checkMalformedSecurityResponses()
    try await checkConcurrentAdapterIsolation()
    return 4
}

private func checkRepositoryThroughAppleAdapter(_ descriptors: ValidatedDescriptors, _ auth: SignerAuthorization) async throws {
    let fixture = SecurityItemFixture(group: "synthetic.northvault.tests")
    let adapter = AppleWalletKeychain(accessGroup: "synthetic.northvault.tests", operations: fixture.operations)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("northvault-keychain-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EncryptedFileStore(directory: root, coordinator: TestFileCoordinator())
    let repository = WalletRepository(files: files, keychain: adapter)
    let created = try await repository.create(name: "Regtest adapter recovery", descriptors: descriptors,
        authorizations: [auth], secretMode: .local, cacheMode: .local)
    try require(try await repository.unlock(created.stored).payload == created.payload, "DEK-backed repository unlock through Apple adapter")
    try await repository.cache(created, mode: .local) // Existing record exercises SecItemUpdate.
    let id = try await repository.secrets.summaries()[0].id
    try await repository.secrets.move(id: id, from: .local, to: .synchronized)
    try await repository.moveCache(created, from: .local, to: .synchronized)
    try require(try await repository.hasCachedDEK(created.stored.envelope), "synchronized DEK visible through adapter")
    try await repository.clearCache(created.stored.envelope, mode: .synchronized)
    try require(try await repository.unlock(created.stored).dek == created.dek, "synchronized recovery secret unlocks after DEK deletion")
    try await adapter.save(Data([9]), id: "unrelated.fixture", mode: .local)
    try require(try await repository.secrets.summaries().count == 1, "secret enumeration excludes unrelated key records")
    try await repository.secrets.move(id: id, from: .synchronized, to: .local)
    try await repository.secrets.delete(id, mode: .local)
    try await repository.secrets.delete(id, mode: .local) // Idempotent not-found delete.
    try require(try await repository.secrets.summaries().isEmpty, "deleted recovery secret absent")
    do {
        _ = try await repository.unlock(created.stored)
        throw CheckFailure(message: "missing keys unexpectedly unlocked repository")
    } catch VaultError.missingKey {}
    try require(try await repository.unlock(created.stored, manual: auth.secret).payload == created.payload, "manual recovery still works after key removal")
    try fixture.checkQueries()
}

private func checkAdapterErrorPropagation() async throws {
    let fixture = SecurityItemFixture()
    let adapter = AppleWalletKeychain(operations: fixture.operations)
    let original = Data(repeating: 7, count: 32)
    try require(try await adapter.load(id: "missing", mode: .local) == nil, "missing individual key returns nil")
    try require(try await adapter.records(prefix: "secret.").isEmpty, "empty enumeration returns empty")
    try await adapter.save(original, id: "fixture", mode: .local)
    fixture.clearCalls()
    fixture.respond(.update, status: errSecAuthFailed)
    try await expectKeychainStatus(errSecAuthFailed, "update authentication error") { try await adapter.save(Data([1]), id: "fixture", mode: .local) }
    try require(fixture.callSequence() == [.update], "failed update must not fall back to add")
    try require(try await adapter.load(id: "fixture", mode: .local) == original, "failed update preserves saved key")
    fixture.respond(.add, status: errSecNotAvailable)
    try await expectKeychainStatus(errSecNotAvailable, "add unavailable") { try await adapter.save(original, id: "new", mode: .local) }
    try require(try await adapter.load(id: "new", mode: .local) == nil, "failed add creates no key")
    fixture.respond(.copy, status: errSecInteractionNotAllowed)
    try await expectKeychainStatus(errSecInteractionNotAllowed, "locked lookup") { _ = try await adapter.load(id: "fixture", mode: .local) }
    fixture.respond(.copy, status: errSecMissingEntitlement)
    try await expectKeychainStatus(errSecMissingEntitlement, "enumeration entitlement failure") { _ = try await adapter.records(prefix: "secret.") }
    fixture.respond(.delete, status: errSecAuthFailed)
    try await expectKeychainStatus(errSecAuthFailed, "deletion authentication failure") { try await adapter.delete(id: "fixture", mode: .local) }
    try require(try await adapter.load(id: "fixture", mode: .local) == original, "failed deletion preserves recovery material")
    try fixture.checkQueries()
}

private func checkMalformedSecurityResponses() async throws {
    let fixture = SecurityItemFixture()
    let adapter = AppleWalletKeychain(operations: fixture.operations)
    for result in [nil, "not key bytes" as NSString] as [CFTypeRef?] {
        fixture.respond(.copy, status: errSecSuccess, result: result)
        try await expectKeychainStatus(errSecDecode, "malformed successful lookup") { _ = try await adapter.load(id: "fixture", mode: .local) }
    }
    for result in [nil, Data([1]) as NSData] as [CFTypeRef?] {
        fixture.respond(.copy, status: errSecSuccess, result: result)
        try await expectKeychainStatus(errSecDecode, "malformed successful enumeration") { _ = try await adapter.records(prefix: "secret.") }
    }
    for row in [
        [kSecValueData as String: Data([1])],
        [kSecAttrAccount as String: "secret.fixture", kSecValueData as String: "not data"],
        [kSecAttrAccount as String: "secret.fixture"]
    ] as [[String: Any]] {
        fixture.respond(.copy, status: errSecSuccess, result: [row] as NSArray)
        try await expectKeychainStatus(errSecDecode, "incomplete recovery record must not disappear") { _ = try await adapter.records(prefix: "secret.") }
    }
    let rows: [[String: Any]] = [
        [kSecAttrAccount as String: "unrelated", kSecValueData as String: "ignored"],
        [kSecAttrAccount as String: "secret.local", kSecValueData as String: Data([1]), kSecAttrSynchronizable as String: false],
        [kSecAttrAccount as String: "secret.synced", kSecValueData as String: Data([2]), kSecAttrSynchronizable as String: true]
    ]
    fixture.respond(.copy, status: errSecSuccess, result: rows as NSArray)
    let records = try await adapter.records(prefix: "secret.")
    try require(records.count == 2 && records[0].2 == .local && records[1].2 == .synchronized, "valid mixed-mode enumeration recovers after malformed response")
    try fixture.checkQueries()
}

private func checkConcurrentAdapterIsolation() async throws {
    let fixture = SecurityItemFixture()
    let adapter = AppleWalletKeychain(operations: fixture.operations)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<12 {
            group.addTask {
                let mode: KeyStorageMode = index.isMultiple(of: 2) ? .local : .synchronized
                let data = Data(repeating: UInt8(index), count: 32)
                let id = "secret.concurrent.\(index)"
                try await adapter.save(data, id: id, mode: mode)
                try require(try await adapter.load(id: id, mode: mode) == data, "concurrent key lookup matches its request")
                let other: KeyStorageMode = mode == .local ? .synchronized : .local
                try require(try await adapter.load(id: id, mode: other) == nil, "key lookup must not cross sync modes")
            }
        }
        try await group.waitForAll()
    }
    try require(try await adapter.records(prefix: "secret.concurrent.").count == 12, "concurrent unique writes preserved")
    try fixture.checkQueries()
}
