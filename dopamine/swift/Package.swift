// swift-tools-version:5.9
//
// Dopamine — Swift / Metal port (vertical slice).
//
// Mirrors the web monorepo's package layout: a shared `DopamineCore` runtime
// (the `.dope` loader + mapping grammar, OKLCH color, tempo primitives, the
// registry + mood-registry, and the resolve pipeline) plus ONE effect package,
// `DopamineEffectSolarbloom`, that contributes only {Metal shader + bespoke
// tempo} — exactly the per-effect surface the web keeps.
//
// HARD PORTABILITY RULE: the package must build on Linux with NO Apple
// toolchain. So every Metal / MetalKit / UIKit type is wrapped in
// `#if canImport(Metal)` / `#if canImport(UIKit)`. On Linux you get the
// portable core + the portable parts of the effect (its bespoke tempo,
// uniform-struct shape, and the bundled `.dope`); the Metal host + the shader
// pass-runner only compile on macOS/iOS. The shared `.dope` JSON is bundled as
// a resource into BOTH the core (the byte-parity test) and the effect (its
// runtime data), proving the data spine is shared verbatim across platforms.

import PackageDescription

let package = Package(
    name: "Dopamine",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "DopamineCore", targets: ["DopamineCore"]),
        .library(name: "DopamineEffectSolarbloom", targets: ["DopamineEffectSolarbloom"]),
        .library(name: "DopamineEffectAurora", targets: ["DopamineEffectAurora"]),
        .library(name: "DopamineEffectComic", targets: ["DopamineEffectComic"]),
        .library(name: "DopamineEffectConfetti", targets: ["DopamineEffectConfetti"]),
        .library(name: "DopamineEffectFail", targets: ["DopamineEffectFail"]),
        .library(name: "DopamineEffectHeartburst", targets: ["DopamineEffectHeartburst"]),
        .library(name: "DopamineEffectInkstroke", targets: ["DopamineEffectInkstroke"]),
        .library(name: "DopamineEffectLightning", targets: ["DopamineEffectLightning"]),
        .library(name: "DopamineEffectRipple", targets: ["DopamineEffectRipple"]),
    ],
    targets: [
        .target(
            name: "DopamineCore",
            resources: [
                // Bundled so the cross-platform byte-parity test can load the
                // SAME `.dope` bytes the effect ships.
                .copy("Resources/solarbloom.dope.json"),
            ]
        ),
        .target(
            name: "DopamineEffectSolarbloom",
            dependencies: ["DopamineCore"],
            resources: [
                // The EXACT web `.dope` (same bytes) + the MSL shader. On Linux
                // the .metal file is just an unbuilt resource; on macOS/iOS it is
                // compiled into a `default.metallib` by the Swift build.
                .copy("Resources/solarbloom.dope.json"),
                .process("Shaders"),
            ]
        ),
        .target(
            name: "DopamineEffectAurora",
            dependencies: ["DopamineCore"],
            resources: [
                .copy("Resources/aurora.dope.json"),
                .process("Shaders"),
            ]
        ),
        .target(
            name: "DopamineEffectComic",
            dependencies: ["DopamineCore"],
            resources: [
                .copy("Resources/comic.dope.json"),
                .process("Shaders"),
            ]
        ),
        .target(
            name: "DopamineEffectConfetti",
            dependencies: ["DopamineCore"],
            resources: [
                .copy("Resources/confetti.dope.json"),
                .process("Shaders"),
            ]
        ),
        .target(
            name: "DopamineEffectFail",
            dependencies: ["DopamineCore"],
            resources: [
                .copy("Resources/fail.dope.json"),
                .process("Shaders"),
            ]
        ),
        .target(
            name: "DopamineEffectHeartburst",
            dependencies: ["DopamineCore"],
            resources: [
                .copy("Resources/heartburst.dope.json"),
                .process("Shaders"),
            ]
        ),
        .target(
            name: "DopamineEffectInkstroke",
            dependencies: ["DopamineCore"],
            resources: [
                .copy("Resources/inkstroke.dope.json"),
                .process("Shaders"),
            ]
        ),
        .target(
            name: "DopamineEffectLightning",
            dependencies: ["DopamineCore"],
            resources: [
                .copy("Resources/lightning.dope.json"),
                .process("Shaders"),
            ]
        ),
        .target(
            name: "DopamineEffectRipple",
            dependencies: ["DopamineCore"],
            resources: [
                .copy("Resources/ripple.dope.json"),
                .process("Shaders"),
            ]
        ),
        .testTarget(
            name: "DopamineCoreTests",
            dependencies: ["DopamineCore", "DopamineEffectSolarbloom"],
            resources: [
                .copy("Fixtures/solarbloom-parity.json"),
            ]
        ),
    ]
)
