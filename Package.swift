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
        // The published SDK, by URL — which is the line the documentation tells third parties to
        // write, so this example had better be able to use it too. `build.sh` finds the headers in
        // the resolved checkout, or in a sibling clone when you have one open beside this.
        .package(url: "https://github.com/hkiam/PeachCommanderPluginSDK.git", from: "1.0.0"),
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
            dependencies: [
                "ISOPlugin",
                // The headers, so the ABI test can check its hand-written struct offsets against
                // the real layout. Depending on the *contract* is not the same as depending on the
                // plugin, which that test deliberately does not.
                .product(name: "CPeachCommanderPlugin", package: "PeachCommanderPluginSDK"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
