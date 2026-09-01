// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkillKit",
    platforms: [
        .macOS(.v15)
    ],

    products: [
        .library(
            name: "SkillKitLib",
            targets: ["SkillKitLib"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr", from: "2.2.1"),
        .package(url: "https://github.com/brokenhandsio/cmark-gfm.git", from: "2.1.0"),
    ],
    targets: [
        .target(
            name: "SkillKitLib",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "cmark", package: "cmark-gfm"),
            ],
            path: "SkillKit",
            exclude: [
                "Info.plist",
                "App/SkillKitApp.swift",
                "SkillKit.entitlements",
                "SkillKitLocalRelease.entitlements",
                "Resources/PrivacyInfo.xcprivacy",
                "Resources/Assets.xcassets"
            ]
        ),
        .testTarget(
            name: "SkillKitTests",
            dependencies: ["SkillKitLib"],
            path: "SkillKitTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
