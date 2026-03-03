import Foundation

/// Diagnostics emitted after every Marching Cubes extraction.
///
/// Provides the metrics required by `SurgeonGradeQualityGate` to decide
/// whether the mesh is fit for surgeon-grade rendering.
struct MCDiagnostics {
    /// Number of triangles in the final mesh (after degenerate culling).
    let numTriangles: Int

    /// Triangles culled because area < `SurgeonGradeQualityGate.minTriangleArea`.
    let numDegenerateCulled: Int

    /// Vertices rejected because one or more components were NaN / Inf.
    let numNaNRejected: Int

    /// Connected components (surfaces) counted via adjacency BFS.
    let numComponents: Int

    /// Boundary (non-manifold) edges — edges shared by exactly one triangle.
    let boundaryEdgesCount: Int

    /// Fraction of vertex normals that originally pointed outward
    /// (i.e. did NOT need flipping against the centroid test).
    let normalOutwardRatio: Float

    /// Total vertices in the output mesh.
    let totalVertices: Int

    /// Number of cubes where the Asymptotic Decider was invoked.
    let ambiguousCasesResolved: Int

    /// Number of cubes that fell through to Marching Tetrahedra.
    let tetrahedraFallbacks: Int

    // MARK: - Quality Gate

    /// `true` when the mesh passes every surgeon-grade quality gate.
    var passesSurgeonGrade: Bool {
        guard numTriangles >= SurgeonGradeQualityGate.minMCTriangles else { return false }
        guard normalOutwardRatio >= SurgeonGradeQualityGate.minNormalOutwardRatio else { return false }

        let boundaryRatio = Float(boundaryEdgesCount) / max(1, Float(numTriangles))
        guard boundaryRatio <= SurgeonGradeQualityGate.maxBoundaryEdgeRatio else { return false }

        return true
    }

    /// Human-readable reason if the gate fails, or `nil` when it passes.
    var failReason: String? {
        if numTriangles < SurgeonGradeQualityGate.minMCTriangles {
            return "MC too few triangles: \(numTriangles) < \(SurgeonGradeQualityGate.minMCTriangles)"
        }
        if normalOutwardRatio < SurgeonGradeQualityGate.minNormalOutwardRatio {
            return String(format: "MC normal outward ratio %.2f < %.2f", normalOutwardRatio, SurgeonGradeQualityGate.minNormalOutwardRatio)
        }
        let boundaryRatio = Float(boundaryEdgesCount) / max(1, Float(numTriangles))
        if boundaryRatio > SurgeonGradeQualityGate.maxBoundaryEdgeRatio {
            return String(format: "MC boundary ratio %.2f > %.2f", boundaryRatio, SurgeonGradeQualityGate.maxBoundaryEdgeRatio)
        }
        return nil
    }
}
