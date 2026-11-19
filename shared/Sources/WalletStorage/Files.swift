import Foundation
import CryptoKit
import WalletModels
import WalletCrypto

private func boundedWalletData(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let maximum = 4 * 1024 * 1024
    var data = Data()
    while data.count <= maximum {
        guard let chunk = try handle.read(upToCount: min(65536, maximum + 1 - data.count)), !chunk.isEmpty else { return data }
        data.append(chunk)
    }
    throw VaultError.invalid("Wallet file exceeds 4 MiB")
}

public struct StoredEnvelope: Sendable { public let envelope: WalletEnvelope; public let url: URL; public let digest: Data }
public protocol FileCoordinating: Sendable {
    func coordinate<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T
}
public struct AppleFileCoordinator: FileCoordinating {
    public init() {}
    public func coordinate<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?; var result: Result<T, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in result = Result { try body(coordinatedURL) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in result = Result { try body(coordinatedURL) } }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw VaultError.unavailable("File coordination did not complete") }; return try result.get()
    }
}
public actor EncryptedFileStore {
    public let directory: URL
    private let coordinator: any FileCoordinating
    public init(directory: URL, coordinator: any FileCoordinating = AppleFileCoordinator()) throws {
        self.directory = directory; self.coordinator = coordinator
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func coordinated<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        try coordinator.coordinate(url, writing: writing, body)
    }
    public func read(_ url: URL) throws -> StoredEnvelope {
        try coordinated(url, writing: false) { file in
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 4 * 1024 * 1024 else { throw VaultError.invalid("Wallet file exceeds 4 MiB") }
            let data = try boundedWalletData(file)
            return StoredEnvelope(envelope: try WalletEnvelope.read(data), url: url, digest: Data(SHA256.hash(data: data)))
        }
    }
    public func list() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]).filter { $0.pathExtension == "walletenc" }
    }
    public func save(_ e: WalletEnvelope, expected: StoredEnvelope? = nil, dek: Data) throws -> StoredEnvelope {
        // Do not let structurally valid but unauthenticated data replace a backup.
        _ = try EnvelopeCrypto.decrypt(e, dek: dek)
        let data = try e.serialized()
        let url = expected?.url ?? directory.appendingPathComponent(e.walletId.uuidString.lowercased()).appendingPathExtension("walletenc")
        guard expected == nil || expected!.envelope.walletId == e.walletId else { throw VaultError.invalid("Wallet identity changed") }
        try coordinated(url, writing: true) { file in
            if FileManager.default.fileExists(atPath: file.path) {
                let currentData = try boundedWalletData(file)
                if currentData == data { return }
                guard let expected, Data(SHA256.hash(data: currentData)) == expected.digest,
                      e.parentRevisionId == expected.envelope.revisionId, expected.envelope.revision < UInt64.max, e.revision == expected.envelope.revision + 1,
                      (NSFileVersion.unresolvedConflictVersionsOfItem(at: file) ?? []).isEmpty else {
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    let conflict = directory.appendingPathComponent("\(e.walletId.uuidString.lowercased()).conflict-\(digest).walletenc")
                    if !FileManager.default.fileExists(atPath: conflict.path) { try data.write(to: conflict, options: .atomic) }
                    throw VaultError.conflict
                }
                // Preserve last authenticated version before replacement.
                _ = try WalletEnvelope.read(currentData)
                let backup = directory.appendingPathComponent("\(e.walletId.uuidString.lowercased()).previous-\(expected.envelope.revisionId.uuidString.lowercased()).walletenc")
                if !FileManager.default.fileExists(atPath: backup.path) { try currentData.write(to: backup, options: .atomic) }
            } else if expected != nil { throw VaultError.conflict }
            try data.write(to: file, options: .atomic)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            #endif
        }
        return try read(url)
    }
    public func conflictCopies(_ url: URL) throws -> [URL] {
        var copies: [URL] = []
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            try coordinated(version.url, writing: false) { source in
                let data = try boundedWalletData(source); let envelope = try WalletEnvelope.read(data)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let dest = directory.appendingPathComponent("\(envelope.walletId.uuidString).conflict-\(digest).walletenc")
                if !FileManager.default.fileExists(atPath: dest.path) { try data.write(to: dest, options: .atomic) }
                copies.append(dest)
            }
        }
        return copies // Do not mark conflicts resolved until the user reviews them.
    }
}
public enum VaultSyncState: String, Sendable { case localOnly, discovering, downloading, uploading, current, conflict, unavailable }
@MainActor public final class CloudWalletDiscovery: NSObject, ObservableObject {
    @Published public private(set) var urls: [URL] = []
    @Published public private(set) var states: [URL: VaultSyncState] = [:]
    @Published public private(set) var error: String?
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    public override init() { super.init() }
    public func start() {
        guard observers.isEmpty else { return }
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K ENDSWITH %@", NSMetadataItemFSNameKey, ".walletenc")
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, NSNotification.Name.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in guard let owner = self else { return }; Task { @MainActor in owner.refresh() } })
        }
        if !query.start() { error = "iCloud discovery could not start" }
    }
    public func stop() { query.stop(); observers.forEach(NotificationCenter.default.removeObserver); observers = []; urls = []; states = [:] }
    private func refresh() {
        query.disableUpdates(); defer { query.enableUpdates() }
        var files: [URL] = []; var next: [URL: VaultSyncState] = [:]
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            files.append(url)
            if item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool == true { next[url] = .conflict }
            else if item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool == true { next[url] = .downloading }
            else if item.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool == true { next[url] = .uploading }
            else if item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String != NSMetadataUbiquitousItemDownloadingStatusCurrent { next[url] = .discovering }
            else { next[url] = .current }
        }
        urls = files; states = next
    }
    public func download(_ url: URL) throws { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
    public static func directory(container: String?) async -> URL? {
        await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: container)?.appendingPathComponent("Documents/Wallets", isDirectory: true)
        }.value
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); query.stop() }
}
public final class ScopedFolder {
    public let url: URL
    private let accessing: Bool
    public init(url: URL) { self.url = url; accessing = url.startAccessingSecurityScopedResource() }
    public static func restore(_ data: Data) throws -> ScopedFolder {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: [], bookmarkDataIsStale: &stale)
        #endif
        guard !stale else { throw VaultError.unavailable("Choose the shared folder again to renew access") }
        return ScopedFolder(url: url)
    }
    public func bookmark() throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
    deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}

/// Verified, encrypted offline snapshots. No plaintext catalog or names are written.
public actor EncryptedOfflineCache {
    private let root: URL
    private let coordinator: any FileCoordinating
    public init(root: URL, coordinator: any FileCoordinating = AppleFileCoordinator()) throws {
        self.root = root; self.coordinator = coordinator
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func preserve(_ wallet: UnlockedWallet) throws {
        _ = try EnvelopeCrypto.decrypt(wallet.stored.envelope, dek: wallet.dek)
        let data = try wallet.stored.envelope.serialized()
        let e = wallet.stored.envelope
        let destination = root.appendingPathComponent("\(e.walletId.uuidString).\(e.revisionId.uuidString).walletenc")
        try coordinator.coordinate(destination, writing: true) { url in
            if FileManager.default.fileExists(atPath: url.path) {
                guard try boundedWalletData(url) == data else { throw VaultError.conflict }
            } else { try data.write(to: url, options: .atomic) }
        }
    }
    public func snapshots() throws -> [URL] {
        // Retain access to older valid snapshots even when a newer file is corrupt.
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "walletenc" }
    }
}
