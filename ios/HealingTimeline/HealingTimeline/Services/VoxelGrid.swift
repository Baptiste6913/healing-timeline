import Foundation
import simd

/// A uniform 3D voxel grid for point cloud fusion and noise reduction.
///
/// Each voxel accumulates weighted position sums and counts.
/// After all points are inserted, `extract()` returns the centroid of each
/// occupied voxel — effectively a noise-reducing spatial average.
final class VoxelGrid {

    /// Accumulated voxel data.
    struct Voxel {
        var positionSum: SIMD3<Float> = .zero
        var weightSum: Float = 0
        var count: Int = 0

        var centroid: SIMD3<Float>? {
            guard weightSum > 0 else { return nil }
            return positionSum / weightSum
        }
    }

    /// A fused point extracted from the voxel grid.
    struct FusedPoint {
        let position: SIMD3<Float>
        let weight: Float       // accumulated confidence
        let sampleCount: Int    // how many raw points contributed
    }

    let voxelSize: Float
    let origin: SIMD3<Float>
    let gridDims: SIMD3<Int>  // (nx, ny, nz)

    private var voxels: [Voxel]

    /// Create a voxel grid spanning a given bounding box.
    ///
    /// - Parameters:
    ///   - boundsMin: Minimum corner of the volume (meters).
    ///   - boundsMax: Maximum corner of the volume (meters).
    ///   - voxelSize: Side length of each cubic voxel (meters).
    init(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, voxelSize: Float) {
        self.voxelSize = voxelSize
        self.origin = boundsMin

        let extent = boundsMax - boundsMin
        let nx = max(1, Int(ceil(extent.x / voxelSize)))
        let ny = max(1, Int(ceil(extent.y / voxelSize)))
        let nz = max(1, Int(ceil(extent.z / voxelSize)))
        self.gridDims = SIMD3<Int>(nx, ny, nz)

        self.voxels = [Voxel](repeating: Voxel(), count: nx * ny * nz)
    }

    /// Total number of voxels in the grid.
    var totalVoxels: Int { gridDims.x * gridDims.y * gridDims.z }

    /// Insert a single 3D point with weight.
    func insert(point: SIMD3<Float>, weight: Float = 1.0) {
        guard let idx = voxelIndex(for: point) else { return }
        voxels[idx].positionSum += point * weight
        voxels[idx].weightSum += weight
        voxels[idx].count += 1
    }

    /// Insert a batch of points from an unprojection result.
    func insertBatch(points: [DepthUnprojector.PointSample]) {
        for p in points {
            insert(point: p.position, weight: p.confidence)
        }
    }

    /// Extract fused points from all occupied voxels.
    ///
    /// - Parameter minSamples: Minimum number of raw points a voxel must contain
    ///   to be emitted (noise filter). Default 2.
    /// - Returns: Array of fused points.
    func extract(minSamples: Int = 2) -> [FusedPoint] {
        var result: [FusedPoint] = []
        result.reserveCapacity(occupiedCount())

        for voxel in voxels {
            guard voxel.count >= minSamples, let centroid = voxel.centroid else { continue }
            result.append(FusedPoint(
                position: centroid,
                weight: voxel.weightSum,
                sampleCount: voxel.count
            ))
        }

        return result
    }

    /// Number of occupied voxels (count > 0).
    func occupiedCount() -> Int {
        voxels.reduce(0) { $0 + ($1.count > 0 ? 1 : 0) }
    }

    /// Reset all voxels to empty.
    func clear() {
        voxels = [Voxel](repeating: Voxel(), count: totalVoxels)
    }

    // MARK: - Private

    private func voxelIndex(for point: SIMD3<Float>) -> Int? {
        let rel = point - origin
        let ix = Int(floor(rel.x / voxelSize))
        let iy = Int(floor(rel.y / voxelSize))
        let iz = Int(floor(rel.z / voxelSize))

        guard ix >= 0, ix < gridDims.x,
              iy >= 0, iy < gridDims.y,
              iz >= 0, iz < gridDims.z else { return nil }

        return iz * (gridDims.x * gridDims.y) + iy * gridDims.x + ix
    }
}
