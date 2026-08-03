// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "teach-touch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "HIDCore",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        // Stage 0 — decode the report descriptor.
        .executableTarget(name: "hid-descriptor", dependencies: ["HIDCore"]),
        // Stage 1 — flip Input Mode and stream contacts.
        .executableTarget(name: "hid-stream", dependencies: ["HIDCore"]),
        // Stage 2 — follow fingers across frames.
        .executableTarget(name: "hid-track", dependencies: ["HIDCore"]),
        // Event synthesis. Split from HIDCore so the hardware layer stays free
        // of CoreGraphics and the recognizers remain testable offline.
        .target(
            name: "TouchEvents",
            dependencies: ["HIDCore"],
            linkerSettings: [.linkedFramework("CoreGraphics"),
                             .linkedFramework("ApplicationServices")]
        ),
        // Stage 4 — two-finger scrolling.
        .executableTarget(name: "touch-scroll", dependencies: ["HIDCore", "TouchEvents"]),
        // Diagnostic: measure what happens after CGEventPost.
        .executableTarget(name: "pointer-latency", dependencies: []),
        // Stage 5 recon — learn the undocumented gesture CGEvent encoding.
        .executableTarget(name: "gesture-probe", dependencies: ["HIDCore", "TouchEvents"]),
        // Stage 5 — post candidate gesture events and see what responds.
        .executableTarget(name: "gesture-emit", dependencies: ["HIDCore", "TouchEvents"]),
        // Stages 3 + 4 — the actual driver: pointer, taps and scrolling.
        .executableTarget(name: "touchd", dependencies: ["HIDCore", "TouchEvents"]),
        // Visual tuning panel. Writes the file touchd watches. AppKit rather
        // than SwiftUI: this Command Line Tools install has no macro plugins,
        // so @State and friends do not resolve — the same gap that rules out
        // XCTest here.
        .executableTarget(
            name: "tuner",
            dependencies: ["TouchEvents"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Tests run as a plain executable: this Command Line Tools install has
        // neither a usable XCTest nor a working Testing.framework.
        //   swift run hidcore-tests
        .executableTarget(name: "hidcore-tests", dependencies: ["HIDCore", "TouchEvents"]),
    ]
)
