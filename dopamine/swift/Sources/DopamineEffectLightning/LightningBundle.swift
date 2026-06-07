// Exposes the effect's resource bundle so an APP target (the iOS demo) can load
// the compiled `default.metallib` SwiftPM built from this package's `Shaders/`.
//
// `Bundle.module` is internal to the package that declares the resources, so an
// app linking `DopamineEffectLightning` cannot reach the metallib directly.
// This tiny public accessor hands it over. Metal-only: the metallib only exists
// on an Apple toolchain build, and on Linux there is no Metal to load it with.

#if canImport(Metal)
import Foundation

public enum LightningResources {
    /// The effect package's resource bundle (contains the compiled
    /// `default.metallib` + the bundled `.dope`). Use with
    /// `device.makeDefaultLibrary(bundle: LightningResources.bundle)`.
    public static var bundle: Bundle { .module }
}
#endif
