import Foundation
import simd

/// Maps vertices between two meshes using barycentric coordinates.
///
/// Given a "source" mesh (canonical ARKit) and a "target" mesh (dense render),
/// each target vertex is expressed as barycentric coordinates on the nearest
/// source triangle. This allows deformation transfer: when the source mesh
/// is deformed (by healing simulation), the target mesh follows.
///
/// **Surgeon-grade v1:** Uses `TriangleBVH` for O(n·log m) closest-triangle
/// queries instead of the previous O(n·m) brute-force search.
/// Supports binary serialization / deserialization for caching.
final class BarycentricMapper {

    /// Barycentric mapping for one target vertex.
    struct Mapping: Codable {
        let sourceTriangleIndex: Int         // which source triangle
        let barycentricCoords: SIMD3<Float>  // (u, v, w) where u+v+w ≈ 1

        // MARK: - Codable for SIMD3<Float>
        enum CodingKeys: String, CodingKey {
            case sourceTriangleIndex
            case bx, by, bz
        }

        init(sourceTriangleIndex: Int, barycentricCoords: SIMD3<Float>) {
            self.sourceTriangleIndex = sourceTriangleIndex
            self.barycentricCoords = barycentricCoords
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sourceTriangleIndex = try c.decode(Int.self, forKey: .sourceTriangleIndex)
            let x = try c.decode(Float.self, forKey: .bx)
            let y = try c.decode(Float.self, forKey: .by)
            let z = try c.decode(Float.self, forKey: .bz)
            barycentricCoords = SIMD3<Float>(x, y, z)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sourceTriangleIndex, forKey: .sourceTriangleIndex)
            try c.encode(barycentricCoords.x, forKey: .bx)
            try c.encode(barycentricCoords.y, forKey: .by)
            try c.encode(barycentricCoords.z, forKey: .bz)
        }
    }

    let mappings: [Mapping]

    // MARK: - Init (BVH-accelerated)

    /// Pre-compute barycentric mappings from render mesh to canonical mesh.
    ///
    /// For each render vertex, find the closest canonical triangle using a
    /// BVH and compute barycentric coordinates.  O(n·log m) instead of O(n·m).
    ///
    /// - Parameters:
    ///   - renderVertices: Dense render mesh vertices (face-local).
    ///   - canonicalVertices: Canonical ARKit mesh vertices (face-local).
    ///   - canonicalIndices: Canonical mesh triangle indices.
    init(
        renderVertices: [SIMD3<Float>],
        canonicalVertices: [SIMD3<Float>],
        canonicalIndices: [UInt32]
    ) {
        // Build BVH for the canonical mesh (O(n log n))
        let bvh = TriangleBVH(vertices: canonicalVertices, indices: canonicalIndices)

        var result = [Mapping]()
        result.reserveCapacity(renderVertices.count)

        for rv in renderVertices {
            let closest = bvh.closestTriangle(to: rv)
            result.append(Mapping(
                sourceTriangleIndex: closest.triangleIndex,
                barycentricCoords: closest.barycentricCoords
            ))
        }

        self.mappings = result
    }

    /// Init from cached / deserialized mappings.
    init(cachedMappings: [Mapping]) {
        self.mappings = cachedMappings
    }

    // MARK: - Serialization

    /// Serialize mappings to binary `Data` for caching on disk.
    func serialize() -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(mappings)) ?? Data()
    }

    /// Deserialize mappings from previously cached `Data`.
    static func deserialize(from data: Data) -> BarycentricMapper? {
        let decoder = PropertyListDecoder()
        guard let mappings = try? decoder.decode([Mapping].self, from: data) else { return nil }
        return BarycentricMapper(cachedMappings: mappings)
    }

    // MARK: - Transfer

    /// Transfer deformation from canonical mesh to render mesh.
    ///
    /// Given a deformed canonical mesh (e.g. with swelling applied), compute
    /// the corresponding render mesh vertex positions using the pre-computed
    /// barycentric mappings.
    ///
    /// - Parameters:
    ///   - deformedCanonical: Deformed canonical vertices.
    ///   - canonicalIndices: Triangle indices of canonical mesh.
    /// - Returns: Deformed render vertices.
    func transfer(
        deformedCanonical: [SIMD3<Float>],
        canonicalIndices: [UInt32]
    ) -> [SIMD3<Float>] {
        var result = [SIMD3<Float>]()
        result.reserveCapacity(mappings.count)

        for mapping in mappings {
            let t = mapping.sourceTriangleIndex
            let bary = mapping.barycentricCoords

            let i0 = Int(canonicalIndices[t * 3])
            let i1 = Int(canonicalIndices[t * 3 + 1])
            let i2 = Int(canonicalIndices[t * 3 + 2])

            guard i0 < deformedCanonical.count,
                  i1 < deformedCanonical.count,
                  i2 < deformedCanonical.count else {
                result.append(.zero)
                continue
            }

            let v0 = deformedCanonical[i0]
            let v1 = deformedCanonical[i1]
            let v2 = deformedCanonical[i2]

            let deformedPos = v0 * bary.x + v1 * bary.y + v2 * bary.z
            result.append(deformedPos)
        }

        return result
    }

    // MARK: - Closest Point on Triangle

    /// Find the closest point on a triangle to a given point.
    /// Returns barycentric coordinates and distance.
    static func closestPointOnTriangle(
        point: SIMD3<Float>,
        v0: SIMD3<Float>,
        v1: SIMD3<Float>,
        v2: SIMD3<Float>
    ) -> (bary: SIMD3<Float>, distance: Float) {

        let edge0 = v1 - v0
        let edge1 = v2 - v0
        let v0p = v0 - point

        let a = dot(edge0, edge0)
        let b = dot(edge0, edge1)
        let c = dot(edge1, edge1)
        let d = dot(edge0, v0p)
        let e = dot(edge1, v0p)

        let det = a * c - b * b
        var s = b * e - c * d
        var t = b * d - a * e

        if s + t <= det {
            if s < 0 {
                if t < 0 {
                    // Region 4
                    if d < 0 {
                        t = 0
                        s = clampBarycentric(-d / a)
                    } else {
                        s = 0
                        t = clampBarycentric(-e / c)
                    }
                } else {
                    // Region 3
                    s = 0
                    t = clampBarycentric(-e / c)
                }
            } else if t < 0 {
                // Region 5
                t = 0
                s = clampBarycentric(-d / a)
            } else {
                // Region 0
                let invDet = 1.0 / max(det, 1e-10)
                s *= invDet
                t *= invDet
            }
        } else {
            if s < 0 {
                // Region 2
                let tmp0 = b + d
                let tmp1 = c + e
                if tmp1 > tmp0 {
                    let numer = tmp1 - tmp0
                    let denom = a - 2 * b + c
                    s = clampBarycentric(numer / max(denom, 1e-10))
                    t = 1 - s
                } else {
                    s = 0
                    t = clampBarycentric(-e / c)
                }
            } else if t < 0 {
                // Region 6
                let tmp0 = b + e
                let tmp1 = a + d
                if tmp1 > tmp0 {
                    let numer = tmp1 - tmp0
                    let denom = a - 2 * b + c
                    t = clampBarycentric(numer / max(denom, 1e-10))
                    s = 1 - t
                } else {
                    t = 0
                    s = clampBarycentric(-d / a)
                }
            } else {
                // Region 1
                let numer = (c + e) - (b + d)
                let denom = a - 2 * b + c
                s = clampBarycentric(numer / max(denom, 1e-10))
                t = 1 - s
            }
        }

        let closestPoint = v0 + edge0 * s + edge1 * t
        let distance = length(closestPoint - point)

        // Convert to standard barycentric (w, u, v) where w = 1 - s - t
        let bary = SIMD3<Float>(1 - s - t, s, t)

        return (bary, distance)
    }

    private static func clampBarycentric(_ v: Float) -> Float {
        max(0, min(1, v))
    }
}
