import Foundation
import simd

/// Simple cylindrical UV unwrapping for face meshes.
///
/// Maps 3D vertices to 2D texture coordinates using a cylindrical projection
/// centered on the face. Suitable for the nose+midface ROI.
enum UVUnwrapper {

    /// Compute cylindrical UV coordinates for a set of vertices.
    ///
    /// The projection axis is Y (vertical). U wraps around the face horizontally,
    /// V maps the vertical extent linearly.
    ///
    /// - Parameters:
    ///   - vertices: 3D vertex positions (face-local space).
    ///   - center: Center of projection (default: centroid).
    /// - Returns: Per-vertex UV coordinates in [0, 1].
    static func cylindricalUnwrap(
        vertices: [SIMD3<Float>],
        center: SIMD3<Float>? = nil
    ) -> [SIMD2<Float>] {
        guard !vertices.isEmpty else { return [] }

        let origin: SIMD3<Float>
        if let c = center {
            origin = c
        } else {
            var centroid = SIMD3<Float>.zero
            for v in vertices { centroid += v }
            centroid /= Float(vertices.count)
            origin = centroid
        }

        // Compute angular range and Y range
        var minY: Float = .greatestFiniteMagnitude
        var maxY: Float = -.greatestFiniteMagnitude
        var angles: [Float] = []

        for v in vertices {
            let rel = v - origin
            let angle = atan2(rel.x, rel.z) // -pi..pi
            angles.append(angle)
            minY = min(minY, rel.y)
            maxY = max(maxY, rel.y)
        }

        let yRange = max(0.001, maxY - minY)

        var uvs = [SIMD2<Float>]()
        uvs.reserveCapacity(vertices.count)

        for i in 0..<vertices.count {
            let rel = vertices[i] - origin
            let u = (angles[i] + Float.pi) / (2 * Float.pi)  // 0..1
            let v = (rel.y - minY) / yRange                    // 0..1
            uvs.append(SIMD2<Float>(u, v))
        }

        return uvs
    }

    /// Compute planar UV projection for a roughly planar mesh region.
    ///
    /// Projects vertices onto their best-fit plane and normalizes to [0, 1].
    ///
    /// - Parameters:
    ///   - vertices: 3D vertex positions.
    ///   - normal: Surface normal of the plane (default: estimated from vertices).
    /// - Returns: Per-vertex UV coordinates in [0, 1].
    static func planarUnwrap(
        vertices: [SIMD3<Float>],
        normal: SIMD3<Float>? = nil
    ) -> [SIMD2<Float>] {
        guard vertices.count >= 3 else {
            return vertices.map { _ in SIMD2<Float>(0.5, 0.5) }
        }

        // Compute centroid
        var centroid = SIMD3<Float>.zero
        for v in vertices { centroid += v }
        centroid /= Float(vertices.count)

        // Determine projection plane
        let planeNormal: SIMD3<Float>
        if let n = normal {
            planeNormal = normalize(n)
        } else {
            // Estimate from first 3 non-degenerate vertices
            let v0 = vertices[0]
            let v1 = vertices[min(1, vertices.count - 1)]
            let v2 = vertices[min(2, vertices.count - 1)]
            let n = normalize(cross(v1 - v0, v2 - v0))
            planeNormal = length(n) > 0.5 ? n : SIMD3<Float>(0, 0, 1)
        }

        // Build orthonormal basis on the plane
        let up = abs(dot(planeNormal, SIMD3<Float>(0, 1, 0))) < 0.99
            ? SIMD3<Float>(0, 1, 0)
            : SIMD3<Float>(1, 0, 0)
        let tangent = normalize(cross(up, planeNormal))
        let bitangent = normalize(cross(planeNormal, tangent))

        // Project vertices onto plane
        var us: [Float] = []
        var vs: [Float] = []

        for v in vertices {
            let rel = v - centroid
            us.append(dot(rel, tangent))
            vs.append(dot(rel, bitangent))
        }

        // Normalize to [0, 1]
        let uMin = us.min() ?? 0
        let uMax = us.max() ?? 1
        let vMin = vs.min() ?? 0
        let vMax = vs.max() ?? 1
        let uRange = max(0.001, uMax - uMin)
        let vRange = max(0.001, vMax - vMin)

        return (0..<vertices.count).map { i in
            SIMD2<Float>(
                (us[i] - uMin) / uRange,
                (vs[i] - vMin) / vRange
            )
        }
    }
}
