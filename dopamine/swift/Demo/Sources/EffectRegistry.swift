// Registry of demo effects + a type-erased overlay host.
//
// `MetalOverlayHost<Config>` is generic per effect, so we can't hold hosts for
// different effects in one array directly. `AnyEffectHost` erases the Config:
// `MetalOverlayHost` already exposes everything the demo driver needs publicly,
// so conformance is free. Each registry entry builds an effect's host (from its
// OWN resource bundle / compiled metallib) plus a feeling→`.dope` resolver.
//
// The CI "sequence" autoplay (`-autoplay all`) walks `EffectRegistry.all` in
// order and the screen recording captures the whole run. Each of the eight
// in-flight effect ports adds ONE entry here once merged.

#if canImport(Metal)
import Metal
import QuartzCore
import simd
import DopamineCore
import DopamineEffectSolarbloom
import DopamineEffectAurora
import DopamineEffectComic
import DopamineEffectConfetti
import DopamineEffectFail
import DopamineEffectHeartburst
import DopamineEffectInkstroke
import DopamineEffectLightning
import DopamineEffectRipple

/// Type-erased overlay host. All members below are already public on
/// `MetalOverlayHost<Config>`, so the conformance is empty.
public protocol AnyEffectHost: AnyObject {
    var lightLayer: CAMetalLayer { get }
    var timeScale: Double { get set }
    /// Heavy, ahead-of-time: compile pipelines + build/upload the panel texture.
    func prepare(params: [String: DopeValue]) throws
    /// Cheap: start the prepared effect's clock.
    func play()
    func tick(now: CFTimeInterval, dpr: Float, anchorPx: SIMD2<Float>)
}
extension MetalOverlayHost: AnyEffectHost {}

/// One registered effect: a name + a builder returning a ready host and a
/// feeling→params resolver (nil if the effect failed to load its metallib/dope).
/// Hybrid effects (comic/heartburst) need NO entry here for their panel — the
/// backbone builds it from the effect's `PanelDrawing` conformance.
struct DemoEffect {
    let name: String
    let build: (MTLDevice) -> (host: any AnyEffectHost, resolve: (DopeResolveInput) -> [String: DopeValue])?
}

enum EffectRegistry {
    /// Every effect the demo can play, in sequence order. ONE entry per ported
    /// effect — the eight in-flight Swift ports each append a line here on merge.
    static let all: [DemoEffect] = [
        DemoEffect(name: "solarbloom") { device in
            guard let lib = try? device.makeDefaultLibrary(bundle: SolarbloomResources.bundle),
                  let host = try? MetalOverlayHost(config: SolarbloomConfig(), device: device,
                                                   library: lib, wantsShadow: false),
                  let fx = try? Solarbloom() else { return nil }
            return (host, { (try? fx.resolve($0)) ?? [:] })
        },
        DemoEffect(name: "aurora") { device in
            guard let lib = try? device.makeDefaultLibrary(bundle: AuroraResources.bundle),
                  let host = try? MetalOverlayHost(config: AuroraConfig(), device: device,
                                                   library: lib, wantsShadow: false),
                  let fx = try? Aurora() else { return nil }
            return (host, { (try? fx.resolve($0)) ?? [:] })
        },
        DemoEffect(name: "comic") { device in
            guard let lib = try? device.makeDefaultLibrary(bundle: ComicResources.bundle),
                  let host = try? MetalOverlayHost(config: ComicConfig(), device: device,
                                                   library: lib, wantsShadow: false),
                  let fx = try? Comic() else { return nil }
            return (host, { (try? fx.resolve($0)) ?? [:] })
        },
        DemoEffect(name: "confetti") { device in
            guard let lib = try? device.makeDefaultLibrary(bundle: ConfettiResources.bundle),
                  let host = try? MetalOverlayHost(config: ConfettiConfig(), device: device,
                                                   library: lib, wantsShadow: false),
                  let fx = try? Confetti() else { return nil }
            return (host, { (try? fx.resolve($0)) ?? [:] })
        },
        DemoEffect(name: "fail") { device in
            guard let lib = try? device.makeDefaultLibrary(bundle: FailResources.bundle),
                  let host = try? MetalOverlayHost(config: FailConfig(), device: device,
                                                   library: lib, wantsShadow: false),
                  let fx = try? Fail() else { return nil }
            return (host, { (try? fx.resolve($0)) ?? [:] })
        },
        DemoEffect(name: "heartburst") { device in
            guard let lib = try? device.makeDefaultLibrary(bundle: HeartburstResources.bundle),
                  let host = try? MetalOverlayHost(config: HeartburstConfig(), device: device,
                                                   library: lib, wantsShadow: false),
                  let fx = try? Heartburst() else { return nil }
            return (host, { (try? fx.resolve($0)) ?? [:] })
        },
        DemoEffect(name: "inkstroke") { device in
            guard let lib = try? device.makeDefaultLibrary(bundle: InkstrokeResources.bundle),
                  let host = try? MetalOverlayHost(config: InkstrokeConfig(), device: device,
                                                   library: lib, wantsShadow: false),
                  let fx = try? Inkstroke() else { return nil }
            return (host, { (try? fx.resolve($0)) ?? [:] })
        },
        DemoEffect(name: "lightning") { device in
            guard let lib = try? device.makeDefaultLibrary(bundle: LightningResources.bundle),
                  let host = try? MetalOverlayHost(config: LightningConfig(), device: device,
                                                   library: lib, wantsShadow: false),
                  let fx = try? Lightning() else { return nil }
            return (host, { (try? fx.resolve($0)) ?? [:] })
        },
        DemoEffect(name: "ripple") { device in
            guard let lib = try? device.makeDefaultLibrary(bundle: RippleResources.bundle),
                  let host = try? MetalOverlayHost(config: RippleConfig(), device: device,
                                                   library: lib, wantsShadow: false),
                  let fx = try? Ripple() else { return nil }
            return (host, { (try? fx.resolve($0)) ?? [:] })
        },
    ]

    /// Resolve the autoplay request to an ordered effect list:
    /// `all`/`sequence` → every effect; a specific name → just that one;
    /// anything else → the first registered effect (the manual-Fire default).
    static func resolve(_ requested: String?) -> [DemoEffect] {
        switch requested {
        case "all", "sequence": return all
        case let .some(n):       return all.first(where: { $0.name == n }).map { [$0] } ?? Array(all.prefix(1))
        case .none:              return Array(all.prefix(1))
        }
    }
}
#endif
