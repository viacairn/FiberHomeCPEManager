// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FiberHomeCPEManager",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FHCPECore", targets: ["FHCPECore"]),
        .library(name: "FHCPEMUI", targets: ["FHCPEMUI"]),
        .executable(name: "FiberHomeCPEManager", targets: ["FHCPEM"]),
        .executable(name: "FiberHomeCPEManagerWidget", targets: ["FHCPEMWidget"]),
        .executable(name: "FiberHomeCPEManagerProbe", targets: ["FHCPEMProbe"]),
        // Development-only renderer used to verify layout without screen-recording access.
        // Not placed inside the shipped app bundle.
        .executable(name: "UIRender", targets: ["UIRender"])
    ],
    targets: [
        .target(name: "FHCPECore", resources: [.process("Resources")]),
        .target(name: "FHCPEMUI", dependencies: ["FHCPECore"]),
        .executableTarget(name: "FHCPEM", dependencies: ["FHCPECore", "FHCPEMUI"]),
        .executableTarget(name: "FHCPEMWidget", dependencies: ["FHCPECore"]),
        .executableTarget(name: "UIRender", dependencies: ["FHCPECore", "FHCPEMUI"]),
        .executableTarget(name: "FHCPEMProbe", dependencies: ["FHCPECore"]),
        .testTarget(name: "FHCPECoreTests", dependencies: ["FHCPECore", "FHCPEMUI"])
    ]
)
