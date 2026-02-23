import SwiftUI
import ARKit
import Combine

/// Manages face scanning session state.
@MainActor
final class ScanViewModel: ObservableObject {
    @Published var trackingState: ScanTrackingState = .notTracking
    @Published var instructionText = "Position your face in the frame"
    @Published var canCapture = false
    @Published var capturedMesh: FaceMeshData?

    // Internal
    var arSession: ARSession?
    var faceAnchor: ARFaceAnchor?
    private var stableFrameCount = 0
    private let requiredStableFrames = 15  // ~0.5s at 30fps

    func updateTracking(anchor: ARFaceAnchor?) {
        if let anchor = anchor {
            faceAnchor = anchor
            trackingState = .tracking
            stableFrameCount += 1

            if stableFrameCount >= requiredStableFrames {
                trackingState = .ready
                canCapture = true
                instructionText = "Hold still…"
            } else {
                instructionText = "Aligning… keep steady"
            }
        } else {
            trackingState = .notTracking
            stableFrameCount = 0
            canCapture = false
            instructionText = "Position your face in the frame"
        }
    }

    func lostTracking() {
        trackingState = .notTracking
        stableFrameCount = 0
        canCapture = false
        instructionText = "Face lost — reposition"
    }

    func capture() {
        guard let anchor = faceAnchor else { return }
        instructionText = "Capturing…"
        canCapture = false

        // Extract mesh from ARFaceAnchor
        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count

        var vertices = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var texCoords = [SIMD2<Float>]()
        var zoneWeights = [Float]()

        for i in 0..<vertexCount {
            let v = geometry.vertices[i]
            let vertex = SIMD3<Float>(v.x, v.y, v.z)
            vertices.append(vertex)

            // ARKit face mesh doesn't provide per-vertex normals directly,
            // we'll compute them from the face geometry later
            normals.append(SIMD3<Float>(0, 0, 1)) // placeholder

            let tc = geometry.textureCoordinates[i]
            texCoords.append(SIMD2<Float>(tc.x, tc.y))

            // Compute zone weight based on position
            zoneWeights.append(computeZoneWeight(vertex: vertex))
        }

        // Compute proper normals
        let indices = geometry.triangleIndices.map { UInt32($0) }
        let computedNormals = MeshProcessor.computeNormals(
            vertices: vertices,
            indices: indices
        )
        if computedNormals.count == vertices.count {
            normals = computedNormals
        }

        capturedMesh = FaceMeshData(
            vertices: vertices,
            normals: normals,
            triangleIndices: indices,
            textureCoordinates: texCoords,
            zoneWeights: zoneWeights
        )
    }

    /// Assign zone influence weight based on vertex position on the face mesh.
    private func computeZoneWeight(vertex: SIMD3<Float>) -> Float {
        // ARKit face mesh is centered at nose bridge, Y up, Z forward
        let x = vertex.x
        let y = vertex.y
        let z = vertex.z

        // Nasal tip: near origin, slightly below and forward
        let tipDist = length(vertex - SIMD3<Float>(0, -0.015, 0.03))
        if tipDist < 0.012 { return 1.0 }

        // Dorsum: along nose ridge
        let dorsumDist = abs(x) + abs(y + 0.005) * 2
        if dorsumDist < 0.015 && z > 0.02 { return 0.7 }

        // Alar: sides of nose
        if abs(x) > 0.008 && abs(x) < 0.02 && y < 0 && y > -0.025 && z > 0.015 {
            return 0.5
        }

        // Periorbital: under/around eyes
        if abs(y - 0.01) < 0.012 && abs(x) < 0.03 && abs(x) > 0.01 {
            return 0.4
        }

        // Cheek: wider face area
        if abs(x) > 0.02 && abs(x) < 0.05 && y < 0.01 && y > -0.04 {
            return 0.2
        }

        return 0.0
    }
}
