import XCTest
final class StorageTests: XCTestCase {
    func testStorageAndRecovery() async throws {
        let fixture = Bundle.module.url(forResource: "descriptors-regtest", withExtension: "json", subdirectory: "Fixtures")!
        let count = try await runStorageChecks(fixture:fixture)
        #if os(macOS)
        XCTAssertEqual(count,69)
        #else
        XCTAssertEqual(count,68)
        #endif
    }
}
