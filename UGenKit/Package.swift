// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UGenKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UGenKit", targets: ["UGenKit"]),
        // The stick-free part: models, decoders, renderers, tracking, pipelines, Core ML engine, HTTP server.
        .library(name: "StudioCore", targets: ["StudioCore"]),
        // Mac command-line tool used to test models and post-processing with the stick on the Mac.
        .executable(name: "ugen", targets: ["ugen"]),
    ],
    targets: [
        // Portable C client for the UGen300: loader upload and HailoRT 5.3.0 RPC.
        .target(
            name: "CUGenRT",
            path: "Sources/CUGenRT",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-O2"], .when(configuration: .debug))],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "StudioCore",
            path: "Sources/StudioCore",
            resources: [.process("Resources")],
            // The decoders and image code loop over every pixel and value: unoptimized (a Debug app build)
            // they run about 50x slower (hand screens 1.4 FPS instead of 74), so they are always optimized.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "UGenKit",
            dependencies: ["CUGenRT", "StudioCore"],
            path: "Sources/UGenKit",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "ugen",
            dependencies: ["UGenKit"],
            path: "Sources/ugen"
        ),
        .testTarget(
            name: "UGenKitTests",
            dependencies: ["UGenKit"],
            path: "Tests/UGenKitTests"
        ),
    ]
)
