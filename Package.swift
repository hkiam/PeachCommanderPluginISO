// swift-tools-version:5.9
// PeachCommanderPluginISO — a worked example of a third-party Peach Commander plugin.
//
// SwiftPM is here for the headers and for `swift test`. The plugin *bundle* is built by
// `./build.sh`, because the output has to be a bare dylib inside a bundle directory rather than a
// SwiftPM product — see that script.
import PackageDescription

let package = Package(
    name: "PeachCommanderPluginISO",
    platforms: [.macOS(.v13)],
    dependencies: [
        // A path dependency while the SDK repository has no published tag yet. Replace with:
        //   .package(url: "https://github.com/hkiam/PeachCommanderPluginSDK.git", from: "1.0.0")
        .package(path: "../PeachCommanderPluginSDK"),
    ],
    targets: [
        .target(
            name: "ISOPlugin",
            dependencies: [
                .product(name: "CPeachCommanderPlugin", package: "PeachCommanderPluginSDK"),
            ]
        ),
        // A development aid — `swift run isodump image.iso` — not part of the plugin bundle.
        .executableTarget(name: "isodump", dependencies: ["ISOPlugin"]),
        .testTarget(
            name: "ISOPluginTests",
            dependencies: ["ISOPlugin"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
