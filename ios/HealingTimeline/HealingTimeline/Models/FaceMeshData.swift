import Foundation
import simd

/// Represents a captured or loaded face mesh.
struct FaceMeshData {
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var triangleIndices: [UInt32]
    var textureCoordinates: [SIMD2<Float>]?
    var zoneWeights: [Float]    // per-vertex weight 0-1 for healing zone influence

    var vertexCount: Int { vertices.count }
    var triangleCount: Int { triangleIndices.count / 3 }

    /// Create a copy with displaced vertices for a given healing state.
    func displaced(by state: HealingState) -> FaceMeshData {
        var newVertices = vertices
        let displacementM = state.nasalVolumeDelta / 1000.0 // mm to meters

        for i in 0..<vertices.count {
            let weight = zoneWeights[i]
            let displacement = normals[i] * (displacementM * weight)
            newVertices[i] = vertices[i] + displacement
        }

        return FaceMeshData(
            vertices: newVertices,
            normals: normals,
            triangleIndices: triangleIndices,
            textureCoordinates: textureCoordinates,
            zoneWeights: zoneWeights
        )
    }
}
