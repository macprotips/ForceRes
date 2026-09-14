// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForceRes",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ForceRes", targets: ["ForceRes"]),
        .executable(name: "forceres-probe", targets: ["forceres-probe"]),
        .executable(name: "forceres-dev", targets: ["forceres-dev"]),
        .executable(name: "forceres-vdhost", targets: ["forceres-vdhost"]),
    ],
    targets: [
        // Pure, Foundation-only domain logic. No CoreGraphics. Fully unit tested.
        .target(
            name: "ForceResCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Objective-C shim around private CoreGraphics virtual-display classes.
        // Every symbol is resolved at runtime; nothing here links against a private symbol.
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // CoreGraphics-backed display enumeration, configuration, mirroring, virtual displays.
        .target(
            name: "ForceResDisplay",
            dependencies: ["ForceResCore", "VirtualDisplayBridge"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("IOKit")]
        ),
        // Helper process that owns exactly one virtual display for its lifetime. Bundled inside
        // ForceRes.app/Contents/MacOS and supervised by VirtualDisplayController. A virtual display
        // that has ever been in a mirror set is only removed when its owning process exits
        // (measured on macOS 27), so ownership lives in a disposable process, never in the app.
        .executableTarget(
            name: "forceres-vdhost",
            dependencies: ["ForceResCore", "ForceResDisplay", "VirtualDisplayBridge"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        // The menu bar app.
        .executableTarget(
            name: "ForceRes",
            dependencies: ["ForceResCore", "ForceResDisplay"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("ServiceManagement")]
        ),
        // CLI that dumps every display and mode as JSON (used to record test fixtures).
        .executableTarget(
            name: "forceres-probe",
            dependencies: ["ForceResCore", "ForceResDisplay"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Internal qualification tool (never shipped): applies modes, mirrors, virtual displays,
        // with automatic revert. Used by the lead for live checks on real hardware.
        .executableTarget(
            name: "forceres-dev",
            dependencies: ["ForceResCore", "ForceResDisplay"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ForceResAppTests",
            dependencies: ["ForceRes", "ForceResCore", "ForceResDisplay"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ForceResCoreTests",
            dependencies: ["ForceResCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ForceResDisplayTests",
            dependencies: ["ForceResDisplay", "ForceResCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
