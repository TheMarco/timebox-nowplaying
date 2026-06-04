// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let infoPlist = "\(packageDir)/Sources/TimeboxNowPlaying/Info.plist"

let package = Package(
    name: "TimeboxNowPlaying",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The timebox-studio library (local path for co-development).
        .package(path: "../TimeBox")
    ],
    targets: [
        .executableTarget(
            name: "TimeboxNowPlaying",
            dependencies: [
                .product(name: "TimeboxBluetooth", package: "TimeBox"),
                .product(name: "TimeboxKit", package: "TimeBox")
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist
                ])
            ]
        )
    ]
)
