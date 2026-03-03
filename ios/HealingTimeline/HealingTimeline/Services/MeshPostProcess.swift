import Foundation
import simd

/// Post-processing for meshes extracted by Marching Cubes.
///
/// Includes Laplacian smoothing, decimation, mesh composition
/// (canonical ARKit + dense ROI patch), and normal estimation.
enum MeshPostProcess {

    /// Composed mesh result (canonical + dense ROI patch).
    struct ComposedMesh {
        let canonical: FaceMeshData         // ARKit topology, used for healing simulation
        let render: RenderMeshData          // Dense ROI patch, used for visual rendering
        let patchBoundaryIndices: [Int]     // Indices at ROI boundary (for blending)
    }

    /// Dense render mesh (separate from canonical FaceMeshData).
    struct RenderMeshData {
        var vertices: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var triangleIndices: [UInt32]
        var textureCoordinates: [SIMD2<Float>]?
    }

    // MARK: - Laplacian Smoothing

    /// Apply Laplacian smoothing to reduce marching cubes staircase artifacts.
    ///
    /// - Parameters:
    ///   - mesh: Input mesh (vertices + indices).
    ///   - iterations: Number of smoothing passes.
    ///   - lambda: Smoothing factor (0..1). Higher = more smoothing.
    /// - Returns: Smoothed vertices (same topology).
    static func laplacianSmooth(
        vertices: [SIMD3<Float>],
        indices: [UInt32],
        iterations: Int = 3,
        lambda: Float = 0.5
    ) -> [SIMD3<Float>] {
        guard !vertices.isEmpty, !indices.isEmpty else { return vertices }

        // Build adjacency
        var neighbors = [[Int]](repeating: [], count: vertices.count)
        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])

            neighbors[i0].append(i1); neighbors[i0].append(i2)
            neighbors[i1].append(i0); neighbors[i1].append(i2)
            neighbors[i2].append(i0); neighbors[i2].append(i1)
        }

        // Deduplicate neighbors
        for i in 0..<neighbors.count {
            neighbors[i] = Array(Set(neighbors[i]))
        }

        var current = vertices

        for _ in 0..<iterations {
            var smoothed = current

            for i in 0..<current.count {
                let nbrs = neighbors[i]
                guard !nbrs.isEmpty else { continue }

                var centroid = SIMD3<Float>.zero
                for n in nbrs {
                    centroid += current[n]
                }
                centroid /= Float(nbrs.count)

                smoothed[i] = current[i] + lambda * (centroid - current[i])
            }

            current = smoothed
        }

        return current
    }

    // MARK: - Mesh Composition

    /// Compose a canonical ARKit mesh with a dense ROI patch.
    ///
    /// The canonical mesh keeps its original topology (for healing simulation).
    /// The dense ROI patch replaces the nose+midface region for visual rendering.
    /// A boundary zone blends between the two.
    ///
    /// - Parameters:
    ///   - canonical: The stabilized ARKit face mesh.
    ///   - denseROIMesh: Dense mesh from TSDF/Marching Cubes.
    ///   - roiCenter: Center of the ROI region (face-local).
    ///   - roiRadius: Radius of the ROI (meters).
    ///   - blendWidth: Width of the blending zone at ROI boundary (meters).
    /// - Returns: `ComposedMesh` with both meshes ready for rendering.
    static func compose(
        canonical: FaceMeshData,
        denseROIMesh: MarchingCubes.MeshOutput,
        roiCenter: SIMD3<Float>,
        roiRadius: Float = 0.025,
        blendWidth: Float = 0.008
    ) -> ComposedMesh {

        // Smooth the dense mesh
        let smoothedVerts = laplacianSmooth(
            vertices: denseROIMesh.vertices,
            indices: denseROIMesh.triangleIndices,
            iterations: 3,
            lambda: 0.5
        )

        // Recompute normals after smoothing
        let smoothedNormals = MeshProcessor.computeNormals(
            vertices: smoothedVerts,
            indices: denseROIMesh.triangleIndices
        )

        // Find boundary vertices (at ROI edge)
        var boundaryIndices: [Int] = []
        let outerRadius = roiRadius + blendWidth
        for i in 0..<smoothedVerts.count {
            let dist = length(smoothedVerts[i] - roiCenter)
            if dist > roiRadius && dist < outerRadius {
                boundaryIndices.append(i)
            }
        }

        let renderMesh = RenderMeshData(
            vertices: smoothedVerts,
            normals: smoothedNormals,
            triangleIndices: denseROIMesh.triangleIndices,
            textureCoordinates: nil  // UV unwrapping done in Phase 4
        )

        return ComposedMesh(
            canonical: canonical,
            render: renderMesh,
            patchBoundaryIndices: boundaryIndices
        )
    }

    // MARK: - Normal Estimation from Point Cloud

    /// Estimate normals for a point cloud using local PCA.
    ///
    /// For each point, finds K nearest neighbors and fits a plane.
    /// The plane normal becomes the point normal.
    ///
    /// - Parameters:
    ///   - points: 3D point positions.
    ///   - k: Number of nearest neighbors (default 10).
    /// - Returns: Per-point normal vectors.
    static func estimateNormals(points: [SIMD3<Float>], k: Int = 10) -> [SIMD3<Float>] {
        guard !points.isEmpty else { return [] }

        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: points.count)

        // Compute centroid for consistent orientation
        var centroid = SIMD3<Float>.zero
        for p in points { centroid += p }
        centroid /= Float(points.count)

        for i in 0..<points.count {
            // Find K nearest neighbors (brute force for small point clouds)
            let sorted = (0..<points.count)
                .filter { $0 != i }
                .sorted { length(points[$0] - points[i]) < length(points[$1] - points[i]) }
            let kNeighbors = Array(sorted.prefix(k))

            guard kNeighbors.count >= 3 else { continue }

            // Compute covariance matrix
            var meanPt = SIMD3<Float>.zero
            for n in kNeighbors { meanPt += points[n] }
            meanPt += points[i]
            meanPt /= Float(kNeighbors.count + 1)

            var cov = simd_float3x3(diagonal: .zero)
            let allPts = kNeighbors.map { points[$0] } + [points[i]]
            for p in allPts {
                let d = p - meanPt
                cov[0][0] += d.x * d.x
                cov[0][1] += d.x * d.y
                cov[0][2] += d.x * d.z
                cov[1][0] += d.y * d.x
                cov[1][1] += d.y * d.y
                cov[1][2] += d.y * d.z
                cov[2][0] += d.z * d.x
                cov[2][1] += d.z * d.y
                cov[2][2] += d.z * d.z
            }

            // Approximate smallest eigenvector via power iteration on inverse
            // (normal is the eigenvector with smallest eigenvalue)
            var normal = SIMD3<Float>(0, 0, 1)
            if let smallest = smallestEigenvector(cov) {
                normal = smallest
            }

            // Orient normal to point outward (away from centroid)
            let toVertex = points[i] - centroid
            if dot(normal, toVertex) < 0 {
                normal = -normal
            }

            normals[i] = normal
        }

        return normals
    }

    /// Approximate smallest eigenvector of a 3x3 symmetric matrix.
    private static func smallestEigenvector(_ m: simd_float3x3) -> SIMD3<Float>? {
        // Use cross-product of two largest eigenvectors (power iteration)
        // For a 3x3, the smallest eigenvector is orthogonal to the two largest

        // Power iteration for largest eigenvector
        var v1 = SIMD3<Float>(1, 0, 0)
        for _ in 0..<20 {
            v1 = m * v1
            let l = length(v1)
            guard l > 1e-10 else { return nil }
            v1 /= l
        }

        // Deflate and find second largest
        let lambda1 = dot(v1, m * v1)
        let m2 = m - simd_float3x3(columns: (
            v1 * lambda1 * v1.x,
            v1 * lambda1 * v1.y,
            v1 * lambda1 * v1.z
        ))

        var v2 = SIMD3<Float>(0, 1, 0)
        for _ in 0..<20 {
            v2 = m2 * v2
            let l = length(v2)
            guard l > 1e-10 else { return nil }
            v2 /= l
        }

        // Smallest eigenvector is cross product of the two largest
        var v3 = cross(v1, v2)
        let l = length(v3)
        guard l > 1e-10 else { return nil }
        v3 /= l
        return v3
    }
}
