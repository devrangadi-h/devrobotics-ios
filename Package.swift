// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DevRobotics",
    platforms: [
        .iOS("26.0"),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "DevRobotics",
            targets: ["DevRobotics"]
        ),
    ],
    targets: [
        .target(
            name: "DevRobotics",
            resources: [.process("Resources")],
            // Swift 6 mode adds a runtime main-actor assertion to SwiftUI's view closures. On iOS 27 SwiftUI sometimes
            // evaluates `DevRoboticsApp.body` on its AsyncRenderer thread, and the assertion then kills the app at
            // launch (EXC_BREAKPOINT in swift_task_isCurrentExecutor). Swift 5 mode keeps the code identical without it.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
