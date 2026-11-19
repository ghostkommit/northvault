import Foundation

/// Stable, app-owned discovery locations; never scans arbitrary user folders.
public struct WalletLocations: Sendable {
    public let local: URL
    public let documents: URL
    public var inbox: URL { local.appendingPathComponent("Inbox", isDirectory: true) }
    public var offline: URL { local.appendingPathComponent("Offline", isDirectory: true) }
    public var directories: [URL] { [local, inbox, offline, documents] }

    public init(applicationSupport: URL, documents: URL) {
        local = applicationSupport.appendingPathComponent("NorthvaultEncrypted", isDirectory: true)
        self.documents = documents.appendingPathComponent("Northvault/Wallets", isDirectory: true)
    }

    public static var standard: WalletLocations {
        let manager = FileManager.default
        return WalletLocations(applicationSupport: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                               documents: manager.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    /// Missing folders are normal. Discovery neither creates folders nor modifies files.
    public func scan() -> (files: [URL], inaccessible: [URL]) {
        var inaccessible: [URL] = []
        var result: Set<URL> = []
        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                for file in files where file.pathExtension.lowercased() == "walletenc" && !file.lastPathComponent.contains(".previous-") {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isRegularFile == true && values.isSymbolicLink != true { result.insert(file.standardizedFileURL) }
                }
            } catch { inaccessible.append(directory) }
        }
        return (result.sorted { $0.path < $1.path }, inaccessible)
    }
}
