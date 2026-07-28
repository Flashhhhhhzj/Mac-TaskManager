// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mac-TaskManager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(
            name: "Mac-TaskManager",
            targets: ["MacTaskManager"]
        ),
        .executable(
            name: "MacFanHelper",
            targets: ["MacFanHelper"]
        ),
        .executable(
            name: "CoolModeAlgorithmChecks",
            targets: ["CoolModeAlgorithmChecks"]
        )
    ],
    targets: [
        .target(
            name: "MacSMC",
            path: "Sources/MacSMC",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "MacTaskManager",
            dependencies: ["MacSMC"],
            path: "Sources/MacTaskManager",
            linkerSettings: [
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "MacFanHelper",
            dependencies: ["MacSMC"],
            path: "Sources/MacFanHelper",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "CoolModeAlgorithmChecks",
            dependencies: ["MacSMC"],
            path: "Tests/MacSMCTests"
        )
    ]
)
