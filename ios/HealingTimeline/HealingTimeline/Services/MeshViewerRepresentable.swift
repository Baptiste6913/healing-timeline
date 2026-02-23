import SwiftUI
import RealityKit
import simd

/// UIViewRepresentable for rendering the face mesh with healing effects.
struct MeshViewerRepresentable: UIViewRepresentable {
    let meshData: FaceMeshData?
    let bruiseLevel: Float
    let bruiseColor: SIMD3<Float>

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

    func updateMesh(
        meshData: FaceMeshData?,
        bruiseLevel: Float,
        bruiseColor: SIMD3<Float>,
        in arView: ARView
    ) {
        guard let meshData = meshData else { return }

        // Remove existing
        if let existing = meshAnchor {
            arView.scene.removeAnchor(existing)
        }

        // Build mesh descriptor
        var descriptor = MeshDescriptor(name: "faceMesh")
        descriptor.positions = MeshBuffers.Positions(meshData.vertices)
        descriptor.normals = MeshBuffers.Normals(meshData.normals)
        descriptor.primitives = .triangles(meshData.triangleIndices)

        if let texCoords = meshData.textureCoordinates {
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(texCoords)
        }

        guard let meshResource = try? MeshResource.generate(from: [descriptor]) else { return }

        // Material: skin-like with bruise tint
        var material = PhysicallyBasedMaterial()

        // Base skin color
        let skinR: Float = 0.85
        let skinG: Float = 0.72
        let skinB: Float = 0.62

        // Blend with bruise color based on level
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

        // Subsurface (skin-like scattering approximation)
        material.sheen = .init(tint: UIColor(white: 0.3, alpha: 1))

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
}
