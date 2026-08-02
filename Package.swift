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
        // Tests run as a plain executable: this Command Line Tools install has
        // neither a usable XCTest nor a working Testing.framework.
        //   swift run hidcore-tests
        .executableTarget(name: "hidcore-tests", dependencies: ["HIDCore"]),
    ]
)
