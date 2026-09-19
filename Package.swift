// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DisplayAudioFix",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "displayaudiofix", targets: ["DisplayAudioFix"])
    ],
    targets: [
        .executableTarget(
            name: "DisplayAudioFix",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
