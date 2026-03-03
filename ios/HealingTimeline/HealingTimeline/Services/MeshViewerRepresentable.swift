import SwiftUI
import RealityKit
import simd

/// UIViewRepresentable for rendering the face mesh with healing effects.
///
/// Supports two rendering paths:
/// 1. **Canonical mesh** (FaceMeshData): Standard path for coarse/depth-corrected scans.
/// 2. **Render mesh** (RenderMeshData + texture atlas): Surgeon-grade path with dense ROI + baked texture.
///
/// When a render mesh is provided, it takes priority for display.
///
/// **Surgeon-grade v1:** Bruise tinting is performed entirely in the Metal
/// fragment shader (`bruiseSurfaceShader`).  The base albedo atlas is NEVER
/// mutated on the CPU.  This enforces non-negotiable #1.
struct MeshViewerRepresentable: UIViewRepresentable {
    let meshData: FaceMeshData?
    let renderMesh: MeshPostProcess.RenderMeshData?
    let textureAtlas: TextureBaker.BakeResult?
    let bruiseLevel: Float
    let bruiseColor: SIMD3<Float>

    /// Convenience init for canonical-only rendering (backward compatible).
    init(meshData: FaceMeshData?, bruiseLevel: Float, bruiseColor: SIMD3<Float>) {
        self.meshData = meshData
        self.renderMesh = nil
        self.textureAtlas = nil
        self.bruiseLevel = bruiseLevel
        self.bruiseColor = bruiseColor
    }

    /// Full init for surgeon-grade rendering with render mesh + texture.
    init(
        meshData: FaceMeshData?,
        renderMesh: MeshPostProcess.RenderMeshData?,
        textureAtlas: TextureBaker.BakeResult?,
        bruiseLevel: Float,
        bruiseColor: SIMD3<Float>
    ) {
        self.meshData = meshData
        self.renderMesh = renderMesh
        self.textureAtlas = textureAtlas
        self.bruiseLevel = bruiseLevel
        self.bruiseColor = bruiseColor
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        arView.environment.background = .color(.black)

        // Camera
        let camera = PerspectiveCamera()
        camera.position = [0, 0, 0.35]
        camera.look(at: [0, 0, 0], from: camera.position, relativeTo: nil)
        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.addChild(camera)
        arView.scene.addAnchor(cameraAnchor)

        // Lighting
        let lightAnchor = AnchorEntity(world: .zero)
        let light = PointLight()
        light.light.intensity = 1000
        light.light.color = .white
        light.position = [0.2, 0.3, 0.4]
        lightAnchor.addChild(light)

        let fillLight = PointLight()
        fillLight.light.intensity = 400
        fillLight.light.color = UIColor(white: 0.9, alpha: 1)
        fillLight.position = [-0.2, 0.1, 0.3]
        lightAnchor.addChild(fillLight)

        arView.scene.addAnchor(lightAnchor)

        // Gesture: rotate
        arView.installGestures([.rotation, .scale], for: ModelEntity())

        context.coordinator.arView = arView
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateMesh(
            meshData: meshData,
            renderMesh: renderMesh,
            textureAtlas: textureAtlas,
            bruiseLevel: bruiseLevel,
            bruiseColor: bruiseColor,
            in: uiView
        )
    }

    func makeCoordinator() -> MeshViewerCoordinator {
        MeshViewerCoordinator()
    }
}

// MARK: - Coordinator

final class MeshViewerCoordinator {
    weak var arView: ARView?
    private var meshAnchor: AnchorEntity?
    private var meshEntity: ModelEntity?

    /// Cached base texture resource — reused as long as the atlas hash matches.
    private var cachedBaseTexture: TextureResource?
    private var cachedAtlasHash: UInt64?

    func updateMesh(
        meshData: FaceMeshData?,
        renderMesh: MeshPostProcess.RenderMeshData?,
        textureAtlas: TextureBaker.BakeResult?,
        bruiseLevel: Float,
        bruiseColor: SIMD3<Float>,
        in arView: ARView
    ) {
        // Remove existing
        if let existing = meshAnchor {
            arView.scene.removeAnchor(existing)
        }

        // Choose render path: prefer render mesh when available
        let descriptor: MeshDescriptor
        let material: RealityKit.Material

        if let renderMesh = renderMesh {
            descriptor = buildRenderMeshDescriptor(renderMesh)
            material = buildTexturedMaterial(
                textureAtlas: textureAtlas,
                bruiseLevel: bruiseLevel,
                bruiseColor: bruiseColor
            )
        } else if let meshData = meshData {
            descriptor = buildCanonicalMeshDescriptor(meshData)
            material = buildSkinMaterial(bruiseLevel: bruiseLevel, bruiseColor: bruiseColor)
        } else {
            return
        }

        guard let meshResource = try? MeshResource.generate(from: [descriptor]) else { return }

        let entity = ModelEntity(mesh: meshResource, materials: [material])
        entity.generateCollisionShapes(recursive: false)

        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)

        // Enable rotation gesture on mesh
        arView.installGestures([.rotation, .scale], for: entity)

        meshAnchor = anchor
        meshEntity = entity
    }

    // MARK: - Mesh Descriptors

    private func buildCanonicalMeshDescriptor(_ meshData: FaceMeshData) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "faceMesh")
        descriptor.positions = MeshBuffers.Positions(meshData.vertices)
        descriptor.normals = MeshBuffers.Normals(meshData.normals)
        descriptor.primitives = .triangles(meshData.triangleIndices)

        if let texCoords = meshData.textureCoordinates {
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(texCoords)
        }
        return descriptor
    }

    private func buildRenderMeshDescriptor(_ renderMesh: MeshPostProcess.RenderMeshData) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "renderMesh")
        descriptor.positions = MeshBuffers.Positions(renderMesh.vertices)
        descriptor.normals = MeshBuffers.Normals(renderMesh.normals)
        descriptor.primitives = .triangles(renderMesh.triangleIndices)

        if let texCoords = renderMesh.textureCoordinates {
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(texCoords)
        }
        return descriptor
    }

    // MARK: - Materials

    /// Standard skin material with bruise tint (canonical path — no texture atlas).
    private func buildSkinMaterial(bruiseLevel: Float, bruiseColor: SIMD3<Float>) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()

        let skinR: Float = 0.85
        let skinG: Float = 0.72
        let skinB: Float = 0.62

        let r = skinR * (1 - bruiseLevel * 0.6) + bruiseColor.x * bruiseLevel * 0.6
        let g = skinG * (1 - bruiseLevel * 0.6) + bruiseColor.y * bruiseLevel * 0.6
        let b = skinB * (1 - bruiseLevel * 0.6) + bruiseColor.z * bruiseLevel * 0.6

        material.baseColor = .init(tint: UIColor(
            red: CGFloat(r),
            green: CGFloat(g),
            blue: CGFloat(b),
            alpha: 1.0
        ))
        material.roughness = .init(floatLiteral: 0.7)
        material.metallic = .init(floatLiteral: 0.0)
        material.sheen = .init(tint: UIColor(white: 0.3, alpha: 1))

        return material
    }

    /// Textured material for surgeon-grade rendering.
    ///
    /// **NON-NEGOTIABLE #1 enforced here:**
    /// The base atlas is converted to a `TextureResource` once and cached.
    /// Bruise tinting is delegated to `BruiseMaterialBuilder` which uses
    /// a Metal surface shader — the atlas pixel data is NEVER modified.
    private func buildTexturedMaterial(
        textureAtlas: TextureBaker.BakeResult?,
        bruiseLevel: Float,
        bruiseColor: SIMD3<Float>
    ) -> RealityKit.Material {
        guard let atlas = textureAtlas else {
            // No atlas → fall back to flat skin material
            return buildSkinMaterial(bruiseLevel: bruiseLevel, bruiseColor: bruiseColor)
        }

        // Verify atlas integrity (detect accidental CPU mutation)
        assert(atlas.verifyIntegrity(), "[MeshViewer] FATAL: Base atlas mutated! Hash mismatch.")

        guard let baseTexture = getOrCreateBaseTexture(from: atlas) else {
            return buildSkinMaterial(bruiseLevel: bruiseLevel, bruiseColor: bruiseColor)
        }

        // Use Metal shader for bruise overlay (non-destructive)
        do {
            return try BruiseMaterialBuilder.build(
                baseTexture: baseTexture,
                bruiseLevel: bruiseLevel,
                bruiseColor: bruiseColor,
                day: 0
            )
        } catch {
            print("[MeshViewer] CustomMaterial failed: \(error). Falling back to PBR.")
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(texture: .init(baseTexture))
            material.roughness = .init(floatLiteral: 0.6)
            material.metallic  = .init(floatLiteral: 0.0)
            return material
        }
    }

    // MARK: - Base Texture Caching

    /// Return a cached `TextureResource` for the given atlas, rebuilding
    /// only when the atlas hash changes.
    private func getOrCreateBaseTexture(from atlas: TextureBaker.BakeResult) -> TextureResource? {
        if let cached = cachedBaseTexture, cachedAtlasHash == atlas.atlasHash {
            return cached
        }

        let texture = createTextureResource(from: atlas)
        cachedBaseTexture = texture
        cachedAtlasHash = atlas.atlasHash
        return texture
    }

    /// Convert `TextureBaker.BakeResult` into a RealityKit `TextureResource`.
    ///
    /// **No bruise blending** — this is the raw immutable atlas.
    /// Color space is linear-sRGB (data is already linearised at bake time).
    private func createTextureResource(
        from atlas: TextureBaker.BakeResult
    ) -> TextureResource? {
        let width = atlas.atlasWidth
        let height = atlas.atlasHeight

        // Create RGBA8 pixel data from linear-space atlas
        var pixels = [UInt8](repeating: 255, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let srcIdx = y * width + x
                let dstIdx = srcIdx * 4

                // Raw linear values — NO bruise blending (enforced)
                pixels[dstIdx]     = UInt8(min(255, max(0, atlas.textureData[srcIdx].x * 255)))
                pixels[dstIdx + 1] = UInt8(min(255, max(0, atlas.textureData[srcIdx].y * 255)))
                pixels[dstIdx + 2] = UInt8(min(255, max(0, atlas.textureData[srcIdx].z * 255)))
                pixels[dstIdx + 3] = 255
            }
        }

        // Use linearSRGB colour space — atlas data was already linearised
        // at TextureBaker ingestion (sRGB→linear in samplePixel).
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let cgImage = context.makeImage() else {
            return nil
        }

        // Semantic `.raw` tells RealityKit the texels are already linear —
        // avoids a second sRGB→linear pass that would cause double-gamma.
        return try? TextureResource.generate(
            from: cgImage,
            options: .init(semantic: .raw)
        )
    }
}
