import Foundation
import simd

/// Represents a captured or loaded face mesh.
struct FaceMeshData {
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var triangleIndices: [UInt32]
    var textureCoordinates: [SIMD2<Float>]?
    var zoneWeights: [Float]    // per-vertex weight 0-1 for healing zone influence

    var scanMode: ScanMode = .coarseStable
    var qualityMetrics: ScanQualityMetrics? = nil

    /// Dense render mesh for surgeon-grade mode (nil for coarse/depth-corrected).
    var renderMesh: MeshPostProcess.RenderMeshData? = nil

    /// Barycentric mapper for deformation transfer (render follows canonical).
    var barycentricMapper: BarycentricMapper? = nil

    /// Texture atlas data (nil unless texture baking completed).
    var textureAtlas: TextureBaker.BakeResult? = nil

    /// Dense ROI coverage metrics (nil unless hybrid scan completed).
    var denseROICoverage: DenseROIBuilder.CoverageMetrics? = nil

    /// Backward-compatible convenience.
    var isSampleMesh: Bool { scanMode == .demo }

    /// Whether this mesh has a high-quality render mesh available.
    var hasRenderMesh: Bool { renderMesh != nil }

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
            zoneWeights: zoneWeights,
            scanMode: scanMode,
            qualityMetrics: qualityMetrics
        )
    }

    /// Create a copy with per-compartment displacement from a v2 healing state.
    ///
    /// Zone weight mapping → compartment:
    ///   ≥ 0.85  →  nasal tip
    ///   ≥ 0.55  →  nasal upper (dorsum/alar) — blended toward tip
    ///   ≥ 0.35  →  alar–periorbital transition — blended
    ///   < 0.35  →  periorbital  (scaled by weight / 0.4)
    func displacedV2(by state: HealingStateV2) -> FaceMeshData {
        var newVertices = vertices

        let tipD   = state.nasalTipDisplacementMM   / 1000.0   // mm → m
        let upperD = state.nasalUpperDisplacementMM / 1000.0
        let periD  = state.periorbitalDisplacementMM / 1000.0

        for i in 0..<vertices.count {
            let w = zoneWeights[i]

            let d: Float
            if w >= 0.85 {
                // Tip zone
                d = tipD
            } else if w >= 0.55 {
                // Dorsum / upper nasal — blend toward tip at higher weights
                let t = (w - 0.55) / 0.30
                d = upperD + (tipD - upperD) * t
            } else if w >= 0.35 {
                // Alar–periorbital transition
                let t = (w - 0.35) / 0.20
                d = periD + (upperD - periD) * t
            } else if w > 0 {
                // Periorbital — scale with distance from center
                d = periD * (w / 0.4)
            } else {
                d = 0
            }

            newVertices[i] = vertices[i] + normals[i] * d
        }

        return FaceMeshData(
            vertices: newVertices,
            normals: normals,
            triangleIndices: triangleIndices,
            textureCoordinates: textureCoordinates,
            zoneWeights: zoneWeights,
            scanMode: scanMode,
            qualityMetrics: qualityMetrics
        )
    }
}
