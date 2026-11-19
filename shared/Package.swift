// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NorthvaultStorage", platforms: [.macOS(.v14), .iOS(.v17)], products: [
    .library(name: "WalletUI", targets: ["WalletUI"]),
    .library(name: "WalletStorage", targets: ["WalletStorage"])
], targets: [
    .target(name: "WalletModels"),
    .target(name: "WalletCrypto", dependencies: ["WalletModels"]),
    .target(name: "WalletStorage", dependencies: ["WalletModels", "WalletCrypto"]),
    .target(name: "WalletUI", dependencies: ["WalletStorage"]),
    .testTarget(name: "WalletStorageTests", dependencies: ["WalletStorage", "WalletUI"], resources: [.copy("Fixtures")])
])
