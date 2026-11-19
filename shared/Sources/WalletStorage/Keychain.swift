import Foundation
import Security
import LocalAuthentication
import WalletModels
import WalletCrypto

public enum KeyStorageMode: String, Codable, CaseIterable, Sendable { case local, synchronized }
public protocol WalletKeychainService: Sendable {
    func save(_ data: Data, id: String, mode: KeyStorageMode) async throws
    func load(id: String, mode: KeyStorageMode) async throws -> Data?
    func delete(id: String, mode: KeyStorageMode) async throws
    func records(prefix: String) async throws -> [(String, Data, KeyStorageMode)]
}

// SECURITY-SENSITIVE: the public initializer always uses Security.framework.
// This internal boundary permits tests to exercise the real query/adapter logic
// without accessing a user's Keychain. No runtime preference selects a substitute.
struct SecurityItemOperations: Sendable {
    let update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    let add: @Sendable (CFDictionary) -> OSStatus
    let copy: @Sendable (CFDictionary) -> (OSStatus, CFTypeRef?)
    let delete: @Sendable (CFDictionary) -> OSStatus

    static let live = SecurityItemOperations(
        update: { SecItemUpdate($0, $1) },
        add: { SecItemAdd($0, nil) },
        copy: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query, &result)
            return (status, result)
        },
        delete: { SecItemDelete($0) }
    )
}

public actor AppleWalletKeychain: WalletKeychainService {
    private let group: String?
    private let service = "northvault.wallet-storage.v1"
    private let operations: SecurityItemOperations
    public init(accessGroup: String? = nil) { group = accessGroup; operations = .live }
    init(accessGroup: String? = nil, operations: SecurityItemOperations) {
        group = accessGroup; self.operations = operations
    }
    private func query(_ id: String?, _ mode: KeyStorageMode?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecUseDataProtectionKeychain as String: true]
        if let id { q[kSecAttrAccount as String] = id }
        if let group { q[kSecAttrAccessGroup as String] = group }
        q[kSecAttrSynchronizable as String] = mode.map { $0 == .synchronized } ?? kSecAttrSynchronizableAny as Any
        return q
    }
    public func save(_ data: Data, id: String, mode: KeyStorageMode) throws {
        var q = query(id, mode)
        let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: mode == .local ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleWhenUnlocked]
        let updated = operations.update(q as CFDictionary, attrs as CFDictionary)
        if updated == errSecItemNotFound {
            q.merge(attrs) { _, new in new }
            let status = operations.add(q as CFDictionary)
            guard status == errSecSuccess else { throw VaultError.keychain(status) }
        } else if updated != errSecSuccess { throw VaultError.keychain(updated) }
    }
    public func load(id: String, mode: KeyStorageMode) throws -> Data? {
        var q = query(id, mode); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = operations.copy(q as CFDictionary)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        guard let data = result as? Data else { throw VaultError.keychain(errSecDecode) }; return data
    }
    public func delete(id: String, mode: KeyStorageMode) throws {
        let status = operations.delete(query(id,mode) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
    }
    public func records(prefix: String) throws -> [(String, Data, KeyStorageMode)] {
        var q = query(nil,nil); q[kSecReturnData as String] = true; q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = operations.copy(q as CFDictionary)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        // A malformed successful response is not an empty Keychain. In particular,
        // never silently omit an unreadable recovery record during enumeration.
        guard let rows = result as? [[String: Any]] else { throw VaultError.keychain(errSecDecode) }
        return try rows.compactMap { row in
            guard let id = row[kSecAttrAccount as String] as? String else { throw VaultError.keychain(errSecDecode) }
            guard id.hasPrefix(prefix) else { return nil }
            guard let data = row[kSecValueData as String] as? Data else { throw VaultError.keychain(errSecDecode) }
            return (id,data,(row[kSecAttrSynchronizable as String] as? Bool == true) ? .synchronized : .local)
        }
    }
}
public struct StoredSignerSecret: Codable, Sendable, Identifiable {
    public let id: UUID
    public let fingerprint: String
    public let bip85Index: UInt32
    public let secret: Data
}
public struct SignerSecretSummary: Sendable, Identifiable {
    public let id: UUID
    public let fingerprint: String
    public let bip85Index: UInt32
    public let mode: KeyStorageMode
    public init(record: StoredSignerSecret, mode: KeyStorageMode) {
        id = record.id; fingerprint = record.fingerprint; bip85Index = record.bip85Index; self.mode = mode
    }
}
public actor SignerSecretStore {
    private let keychain: any WalletKeychainService
    public init(keychain: any WalletKeychainService) { self.keychain = keychain }
    @discardableResult public func save(_ auth: SignerAuthorization, mode: KeyStorageMode) async throws -> UUID {
        // Compare secret bytes, not fingerprint, when reusing a record.
        let existing = try await all()
        let id = existing.first { $0.0.secret == auth.secret.keychainData() && $0.0.bip85Index == auth.index && $0.0.fingerprint == auth.fingerprint }?.0.id ?? UUID()
        let record = StoredSignerSecret(id: id, fingerprint: auth.fingerprint, bip85Index: auth.index, secret: auth.secret.keychainData())
        try await keychain.save(JSONEncoder().encode(record), id: "secret.\(id.uuidString)", mode: mode)
        return id
    }
    public func all() async throws -> [(StoredSignerSecret, KeyStorageMode)] {
        try await keychain.records(prefix: "secret.").map { (_,data,mode) in (try JSONDecoder().decode(StoredSignerSecret.self, from: data),mode) }
    }
    public func summaries() async throws -> [SignerSecretSummary] {
        try await all().map { SignerSecretSummary(record: $0.0, mode: $0.1) }
    }
    public func move(id: UUID, from: KeyStorageMode, to: KeyStorageMode) async throws {
        guard let data = try await keychain.load(id: "secret.\(id.uuidString)", mode: from) else { throw VaultError.missingKey }
        try await move(JSONDecoder().decode(StoredSignerSecret.self, from: data), from: from, to: to)
    }
    public func delete(_ id: UUID, mode: KeyStorageMode) async throws { try await keychain.delete(id: "secret.\(id.uuidString)", mode: mode) }
    public func move(_ record: StoredSignerSecret, from: KeyStorageMode, to: KeyStorageMode) async throws {
        guard from != to else { return }
        let id = "secret.\(record.id.uuidString)"
        try await keychain.save(JSONEncoder().encode(record), id: id, mode: to)
        try await keychain.delete(id: id, mode: from)
    }
}
public protocol HardwareSignerSecretProvider: Sendable {
    func secret(fingerprintHint: String, index: UInt32) async throws -> BIP85Secret
}
public struct ManualSignerSecretProvider: HardwareSignerSecretProvider {
    private let input: @Sendable (String, UInt32) async throws -> String
    public init(input: @escaping @Sendable (String, UInt32) async throws -> String) { self.input = input }
    public func secret(fingerprintHint: String, index: UInt32) async throws -> BIP85Secret { try BIP85Secret(hex: await input(fingerprintHint,index)) }
}
@MainActor public enum DeviceAuthentication {
    public static func authorize() async throws {
        let context = LAContext()
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock encrypted wallet descriptors") else { throw VaultError.authentication }
    }
}
