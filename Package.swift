// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FHCPEM", platforms: [.macOS(.v14)], products: [
    .library(name: "FHCPECore", targets: ["FHCPECore"]),
    .executable(name: "FHCPEM", targets: ["FHCPEM"])
], targets: [
    .target(name: "FHCPECore", resources: [.process("Resources")]),
    .executableTarget(name: "FHCPEM", dependencies: ["FHCPECore"]),
    .testTarget(name: "FHCPECoreTests", dependencies: ["FHCPECore"])
])
