import Foundation
import simd

/// Truncated Signed Distance Function volume for implicit surface reconstruction.
///
/// Each voxel stores a weighted signed distance to the nearest surface.
/// After integration, the zero-crossing isosurface can be extracted via MarchingCubes.
final class TSDFVolume {

    struct TSDFVoxel {
        var tsdf: Float = 1.0       // truncated signed distance (positive = outside)
        var weight: Float = 0       // accumulated integration weight
    }

    let voxelSize: Float
    let origin: SIMD3<Float>
    let dims: SIMD3<Int>            // (nx, ny, nz)
    let truncationDistance: Float    // distance beyond which TSDF is clamped

    private var voxels: [TSDFVoxel]

    /// Create a TSDF volume.
    ///
    /// - Parameters:
    ///   - boundsMin: Minimum corner of the volume.
    ///   - boundsMax: Maximum corner of the volume.
    ///   - voxelSize: Side length of each cubic voxel (meters).
    ///   - truncation: Truncation distance (default 3x voxelSize).
    init(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, voxelSize: Float, truncation: Float? = nil) {
        self.voxelSize = voxelSize
        self.origin = boundsMin
        self.truncationDistance = truncation ?? (voxelSize * 3.0)

        let extent = boundsMax - boundsMin
        let nx = max(1, Int(ceil(extent.x / voxelSize)))
        let ny = max(1, Int(ceil(extent.y / voxelSize)))
        let nz = max(1, Int(ceil(extent.z / voxelSize)))
        self.dims = SIMD3<Int>(nx, ny, nz)

        self.voxels = [TSDFVoxel](repeating: TSDFVoxel(), count: nx * ny * nz)
    }

    /// Total number of voxels.
    var totalVoxels: Int { dims.x * dims.y * dims.z }

    /// Integrate a set of fused points into the TSDF.
    ///
    /// For each voxel center, find its distance to the nearest point surface
    /// and update the running weighted average.
    ///
    /// - Parameters:
    ///   - points: Fused 3D points from PointCloudFusion.
    ///   - normals: Per-point normals (estimated or computed). Must match points count.
    ///   - weight: Integration weight for this batch.
    func integrate(points: [SIMD3<Float>], normals: [SIMD3<Float>], weight: Float = 1.0) {
        guard points.count == normals.count else { return }

        // Build a simple spatial lookup: for each voxel, find nearest points
        // For performance, we iterate points and update nearby voxels
        let truncDist = truncationDistance

        for pi in 0..<points.count {
            let p = points[pi]
            let n = normals[pi]

            // Determine voxel range to update (within truncation distance)
            let radiusVoxels = Int(ceil(truncDist / voxelSize))
            let centerVoxel = voxelCoord(for: p)

            for dz in -radiusVoxels...radiusVoxels {
                for dy in -radiusVoxels...radiusVoxels {
                    for dx in -radiusVoxels...radiusVoxels {
                        let vx = centerVoxel.x + dx
                        let vy = centerVoxel.y + dy
                        let vz = centerVoxel.z + dz

                        guard vx >= 0, vx < dims.x,
                              vy >= 0, vy < dims.y,
                              vz >= 0, vz < dims.z else { continue }

                        let voxelCenter = origin + SIMD3<Float>(
                            (Float(vx) + 0.5) * voxelSize,
                            (Float(vy) + 0.5) * voxelSize,
                            (Float(vz) + 0.5) * voxelSize
                        )

                        // Signed distance: projection onto normal direction
                        let diff = voxelCenter - p
                        let sdf = dot(diff, n)

                        // Truncate
                        guard abs(sdf) < truncDist else { continue }
                        let tsdf = max(-1.0, min(1.0, sdf / truncDist))

                        // Running weighted average
                        let idx = linearIndex(vx, vy, vz)
                        let oldW = voxels[idx].weight
                        let newW = oldW + weight
                        if newW > 0 {
                            voxels[idx].tsdf = (voxels[idx].tsdf * oldW + tsdf * weight) / newW
                            voxels[idx].weight = newW
                        }
                    }
                }
            }
        }
    }

    /// Get TSDF value at a voxel coordinate.
    func tsdfAt(_ x: Int, _ y: Int, _ z: Int) -> Float {
        guard x >= 0, x < dims.x, y >= 0, y < dims.y, z >= 0, z < dims.z else { return 1.0 }
        return voxels[linearIndex(x, y, z)].tsdf
    }

    /// Get weight at a voxel coordinate.
    func weightAt(_ x: Int, _ y: Int, _ z: Int) -> Float {
        guard x >= 0, x < dims.x, y >= 0, y < dims.y, z >= 0, z < dims.z else { return 0 }
        return voxels[linearIndex(x, y, z)].weight
    }

    /// World position of a voxel center.
    func voxelCenterWorld(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
        origin + SIMD3<Float>(
            (Float(x) + 0.5) * voxelSize,
            (Float(y) + 0.5) * voxelSize,
            (Float(z) + 0.5) * voxelSize
        )
    }

    // MARK: - Direct Voxel Access (for tests / analytic fill)

    /// Set a voxel's TSDF value and weight directly.
    func setVoxel(_ x: Int, _ y: Int, _ z: Int, tsdf: Float, weight: Float) {
        guard x >= 0, x < dims.x, y >= 0, y < dims.y, z >= 0, z < dims.z else { return }
        let idx = linearIndex(x, y, z)
        voxels[idx].tsdf = tsdf
        voxels[idx].weight = weight
    }

    // MARK: - Private

    private func linearIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
        z * (dims.x * dims.y) + y * dims.x + x
    }

    private func voxelCoord(for point: SIMD3<Float>) -> SIMD3<Int> {
        let rel = point - origin
        return SIMD3<Int>(
            Int(floor(rel.x / voxelSize)),
            Int(floor(rel.y / voxelSize)),
            Int(floor(rel.z / voxelSize))
        )
    }
}
