import Foundation

/// Centralized quality gates for the surgeon-grade rendering pipeline.
///
/// All thresholds live here so that tests and runtime code share a single
/// source of truth.  Feature-gated behind `FeatureFlags.hybridScan3DEnabled`.
enum SurgeonGradeQualityGate {

    // MARK: - Marching Cubes

    /// Minimum ratio of outward-facing normals after MC extraction.
    static let minNormalOutwardRatio: Float = 0.90

    /// Maximum boundary-edge / triangle ratio.  Higher means more open edges ⟹ non-watertight.
    static let maxBoundaryEdgeRatio: Float = 0.20

    /// Minimum triangle count from MC before we accept the mesh.
    static let minMCTriangles: Int = 50

    // MARK: - Deformation Transfer

    /// Maximum identity-mapping error (meters).
    /// If transferring the *un-deformed* canonical back through the mapper produces
    /// a displacement larger than this, the mapping is considered broken.
    static let maxIdentityErrorM: Float = 0.005

    // MARK: - Texture

    /// Minimum UV-coverage fraction for the baked atlas to be accepted.
    static let minTextureCoverage: Float = 0.30

    // MARK: - Degenerate Geometry

    /// Minimum triangle area (m²) below which a triangle is culled as degenerate.
    static let minTriangleArea: Float = 1e-12
}
