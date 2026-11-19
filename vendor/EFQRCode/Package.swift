// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EFQRCode",
    platforms: [.macOS(.v14)],
    products: [.library(name: "EFQRCode", targets: ["EFQRCode"])],
    targets: [.target(name: "EFQRCode")]
)
