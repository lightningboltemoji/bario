// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bario",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "bario", targets: ["bario"]),
        .library(name: "BarioKit", targets: ["BarioKit"]),
    ],
    dependencies: [
        // The WASM runtime. Pure Swift, so a module is a SwiftPM dependency and not a build
        // system; see .agents/knowledge/13-wasm.md for why an interpreter is enough here.
        // Exact, because the memory cap goes through WasmKit SPI, which any release may change.
        .package(url: "https://github.com/swiftwasm/WasmKit.git", exact: "0.4.2"),
    ],
    targets: [
        // Only exists because shm_open is variadic and therefore unavailable to Swift.
        .target(name: "CBarioShim", path: "Sources/CBarioShim"),
        .target(name: "BarioKit",
                dependencies: [
                    "CBarioShim",
                    .product(name: "WasmKit", package: "WasmKit"),
                    // So a module can be dropped in as WebAssembly text, with no toolchain.
                    .product(name: "WAT", package: "WasmKit"),
                ],
                path: "Sources/BarioKit"),
        .executableTarget(name: "bario", dependencies: ["BarioKit"], path: "Sources/bario"),
        // DESIGN.md §9.3's native producer: Metal into a pair of shared surfaces. Not a product;
        // `swift run surface-example` builds and runs it.
        .executableTarget(name: "surface-example", dependencies: ["BarioKit"], path: "examples/surface"),
        .testTarget(name: "BarioKitTests",
                    dependencies: ["BarioKit", "CBarioShim", .product(name: "WAT", package: "WasmKit")],
                    path: "Tests/BarioKitTests"),
    ]
)
