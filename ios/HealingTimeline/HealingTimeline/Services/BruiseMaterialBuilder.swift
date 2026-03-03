import RealityKit
import Metal

/// Builds a RealityKit `CustomMaterial` with a Metal-based bruise overlay.
///
/// The base albedo atlas is **never** modified — bruise tinting is computed
/// entirely in the fragment shader.  This enforces non-negotiable #1:
/// *"Bruising baked in CPU albedo: FORBIDDEN."*
///
/// The custom parameter packing is:
///   `custom.value = SIMD4(bruiseLevel, bruiseR, bruiseG, bruiseB)`
///
/// The surface shader reads these from `params.uniforms().custom_parameter()`.
enum BruiseMaterialBuilder {

    /// Build a `CustomMaterial` that composites bruise overlay via the Metal
    /// surface shader `bruiseSurfaceShader` defined in `BruiseOverlay.metal`.
    ///
    /// Falls back to a simple `PhysicallyBasedMaterial` if Metal initialisation fails.
    static func build(
        baseTexture: TextureResource,
        bruiseLevel: Float,
        bruiseColor: SIMD3<Float>,
        day: Float
    ) throws -> RealityKit.Material {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary() else {
            // Metal unavailable — graceful fallback
            return makeFallbackMaterial(baseTexture: baseTexture)
        }

        let surfaceShader = CustomMaterial.SurfaceShader(
            named: "bruiseSurfaceShader",
            in: library
        )

        var material = try CustomMaterial(
            surfaceShader: surfaceShader,
            lightingModel: .lit
        )

        // Base texture (immutable atlas)
        material.baseColor = .init(texture: .init(baseTexture))

        // Pack bruise uniforms into the 4-float custom parameter
        material.custom.value = SIMD4<Float>(
            bruiseLevel,
            bruiseColor.x,
            bruiseColor.y,
            bruiseColor.z
        )

        material.roughness = .init(floatLiteral: 0.6)
        material.metallic  = .init(floatLiteral: 0.0)

        return material
    }

    /// Update bruise parameters on an existing `CustomMaterial` without
    /// rebuilding the shader or re-uploading the base texture.
    static func updateBruise(
        on material: inout CustomMaterial,
        bruiseLevel: Float,
        bruiseColor: SIMD3<Float>
    ) {
        material.custom.value = SIMD4<Float>(
            bruiseLevel,
            bruiseColor.x,
            bruiseColor.y,
            bruiseColor.z
        )
    }

    // MARK: - Fallback

    /// A plain PBR material used when the Metal pipeline is unavailable.
    private static func makeFallbackMaterial(baseTexture: TextureResource) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(texture: .init(baseTexture))
        material.roughness = .init(floatLiteral: 0.6)
        material.metallic  = .init(floatLiteral: 0.0)
        return material
    }
}
