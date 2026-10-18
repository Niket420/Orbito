// swift-tools-version:5.10
import Foundation
import PackageDescription

// Embed Info.plist (bundle ID, microphone usage text) into the executable so
// `swift run` gets the same identity and permission prompts as the .app bundle.
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist").path

let package = Package(
    name: "Orbito",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Orbito", targets: ["Orbito"])],
    targets: [
        .executableTarget(
            name: "Orbito",
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
        .testTarget(name: "OrbitoTests", dependencies: ["Orbito"], path: "Tests"),
    ]
)
