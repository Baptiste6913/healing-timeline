import Foundation
import simd

/// Transfers healing-model deformations from canonical mesh to render mesh.
///
/// Architecture:
/// - **Canonical mesh** (ARKit topology): used for healing simulation (swelling, bruising)
/// - **Render mesh** (dense ROI): used for high-quality visual display
///
/// The `BarycentricMapper` links the two. When the canonical mesh is deformed
/// by the healing model, `DeformationTransfer` applies the same deformation
/// to the render mesh while preserving its high-resolution detail.
final class DeformationTransfer {

    /// Configuration for deformation transfer.
    struct Config {
        /// Maximum allowed displacement (meters). Safety clamp.
        var maxDisplacementM: Float = 0.010  // 10mm

        /// Whether to also transfer normals.
        var transferNormals: Bool = true

        static let `default` = Config()
    }

    /// Result of a deformation transfer.
    struct TransferResult {
        let deformedVertices: [SIMD3<Float>]
        let deformedNormals: [SIMD3<Float>]?
        let maxDisplacement: Float           // largest per-vertex displacement (meters)
        let meanDisplacement: Float          // mean per-vertex displacement (meters)
    }

    private let mapper: BarycentricMapper
    private let baseRenderVertices: [SIMD3<Float>]
    private let canonicalIndices: [UInt32]
    private let config: Config

    /// Initialize with pre-computed barycentric mappings.
    ///
    /// - Parameters:
    ///   - mapper: Pre-computed barycentric mapper (render -> canonical).
    ///   - baseRenderVertices: Undeformed render mesh vertices.
    ///   - canonicalIndices: Canonical mesh triangle indices.
    ///   - config: Transfer configuration.
    init(
        mapper: BarycentricMapper,
        baseRenderVertices: [SIMD3<Float>],
        canonicalIndices: [UInt32],
        config: Config = .default
    ) {
        self.mapper = mapper
        self.baseRenderVertices = baseRenderVertices
        self.canonicalIndices = canonicalIndices
        self.config = config
    }

    /// Transfer deformation from a displaced canonical mesh to the render mesh.
    ///
    /// - Parameters:
    ///   - baseCanonical: Undeformed canonical vertices (at t=0 / no healing applied).
    ///   - deformedCanonical: Deformed canonical vertices (with healing displacement).
    ///   - deformedNormals: Deformed canonical normals (optional).
    /// - Returns: `TransferResult` with the deformed render mesh.
    func transfer(
        baseCanonical: [SIMD3<Float>],
        deformedCanonical: [SIMD3<Float>],
        deformedNormals: [SIMD3<Float>]? = nil
    ) -> TransferResult {

        // Method: for each render vertex, compute the displacement at its
        // canonical location, then apply that displacement to the render vertex.
        //
        // This preserves the render mesh's high-frequency detail while
        // transferring the low-frequency healing deformation.

        let baseCanonicalPositions = mapper.transfer(
            deformedCanonical: baseCanonical,
            canonicalIndices: canonicalIndices
        )
        let deformedCanonicalPositions = mapper.transfer(
            deformedCanonical: deformedCanonical,
            canonicalIndices: canonicalIndices
        )

        var deformedRender = [SIMD3<Float>]()
        deformedRender.reserveCapacity(baseRenderVertices.count)

        var maxDisp: Float = 0
        var totalDisp: Float = 0

        for i in 0..<baseRenderVertices.count {
            // Displacement in canonical space
            let displacement = deformedCanonicalPositions[i] - baseCanonicalPositions[i]

            // Clamp for safety
            let dispLen = length(displacement)
            let clampedDisp: SIMD3<Float>
            if dispLen > config.maxDisplacementM {
                clampedDisp = displacement * (config.maxDisplacementM / dispLen)
            } else {
                clampedDisp = displacement
            }

            let deformed = baseRenderVertices[i] + clampedDisp
            deformedRender.append(deformed)

            maxDisp = max(maxDisp, length(clampedDisp))
            totalDisp += length(clampedDisp)
        }

        let meanDisp = baseRenderVertices.isEmpty ? 0 : totalDisp / Float(baseRenderVertices.count)

        // Transfer normals if requested
        var transferredNormals: [SIMD3<Float>]?
        if config.transferNormals, let srcNormals = deformedNormals {
            transferredNormals = transferNormals(srcNormals: srcNormals)
        }

        return TransferResult(
            deformedVertices: deformedRender,
            deformedNormals: transferredNormals,
            maxDisplacement: maxDisp,
            meanDisplacement: meanDisp
        )
    }

    /// Transfer normals from canonical to render mesh using barycentric interpolation.
    private func transferNormals(srcNormals: [SIMD3<Float>]) -> [SIMD3<Float>] {
        var result = [SIMD3<Float>]()
        result.reserveCapacity(mapper.mappings.count)

        for mapping in mapper.mappings {
            let t = mapping.sourceTriangleIndex
            let bary = mapping.barycentricCoords

            let i0 = Int(canonicalIndices[t * 3])
            let i1 = Int(canonicalIndices[t * 3 + 1])
            let i2 = Int(canonicalIndices[t * 3 + 2])

            guard i0 < srcNormals.count,
                  i1 < srcNormals.count,
                  i2 < srcNormals.count else {
                result.append(SIMD3<Float>(0, 0, 1))
                continue
            }

            let n = srcNormals[i0] * bary.x + srcNormals[i1] * bary.y + srcNormals[i2] * bary.z
            let len = length(n)
            result.append(len > 1e-8 ? n / len : SIMD3<Float>(0, 0, 1))
        }

        return result
    }
}
