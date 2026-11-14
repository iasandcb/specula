// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
var remoteDependencies: [Target.Dependency] = [
    "CInflate", "CCryptoShim", "Network",
    .product(name: "BigInt", package: "BigInt")
]
var testDependencies: [Target.Dependency] = ["RemoteCore", "DisplaySupport", "CCryptoShim", "Network"]
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0")
]
#else
var remoteDependencies: [Target.Dependency] = [
    "CInflate",
    .product(name: "BigInt", package: "BigInt")
]
var testDependencies: [Target.Dependency] = ["RemoteCore", "DisplaySupport"]
var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/attaswift/BigInt.git", exact: "5.7.0")
]
#endif

var targets: [Target] = [
    .target(name: "DisplaySupport"),
    .executableTarget(name: "MacDisplayHelper", dependencies: ["DisplaySupport"]),
    .target(
        name: "CInflate",
        path: "Sources/CInflate",
        sources: ["inflate_bridge.c"],
        publicHeadersPath: "include",
        linkerSettings: [.linkedLibrary("z")]
    ),
    .target(
        name: "RemoteCore",
        dependencies: remoteDependencies
    ),
    .testTarget(name: "RemoteCoreTests", dependencies: testDependencies)
]

#if os(Linux)
targets.append(contentsOf: [
    .target(
        name: "CCryptoShim",
        path: "Sources/CCryptoShim",
        sources: ["shim.c"],
        publicHeadersPath: "include",
        linkerSettings: [.linkedLibrary("crypto")]
    ),
    .target(name: "Network", path: "Sources/Network")
])
#endif

let package = Package(
    name: "MacRemote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "MacDisplayHelper", targets: ["MacDisplayHelper"]),
        .library(name: "RemoteCore", targets: ["RemoteCore"])
    ],
    dependencies: packageDependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
