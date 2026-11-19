import Foundation
@main struct StorageChecks {
    static func main() async {
        do {
        let count = try await runStorageChecks(fixture:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("Passed \(count) encrypted-storage checks")
        } catch { FileHandle.standardError.write(Data("Storage checks failed: \(error)\n".utf8)); exit(1) }
    }
}
