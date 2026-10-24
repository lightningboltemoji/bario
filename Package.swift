// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bario",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "bario", targets: ["bario"]),
        .library(name: "BarioKit", targets: ["BarioKit"]),
    ],
    targets: [
        // Only exists because shm_open is variadic and therefore unavailable to Swift.
        .target(name: "CBarioShim", path: "Sources/CBarioShim"),
        // The WASM runtime: wasmtime's Pulley interpreter behind a narrow C ABI, a Rust static
        // library that `make engine` builds, since SwiftPM cannot run cargo. See
        // .agents/knowledge/23-wasmtime.md.
        .binaryTarget(name: "BarioWasm", path: "Frameworks/BarioWasm.xcframework"),
        .target(name: "BarioKit",
                dependencies: ["CBarioShim", "BarioWasm"],
                path: "Sources/BarioKit",
                linkerSettings: [.linkedLibrary("iconv")]),
        .executableTarget(name: "bario", dependencies: ["BarioKit"], path: "Sources/bario"),
        // DESIGN.md §9.3's native producer: Metal into a pair of shared surfaces. Not a product;
        // `swift run surface-example` builds and runs it.
        .executableTarget(name: "surface-example", dependencies: ["BarioKit"], path: "examples/surface"),
        .testTarget(name: "BarioKitTests",
                    dependencies: ["BarioKit", "CBarioShim"],
                    path: "Tests/BarioKitTests"),
    ]
)
