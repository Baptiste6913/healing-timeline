import Foundation
import simd

/// Multi-frame point cloud fusion in face-local coordinates.
///
/// Accumulates depth-unprojected points from multiple frames into a VoxelGrid,
/// producing a noise-reduced dense point cloud of the nose + midface ROI.
final class PointCloudFusion {

    /// Configuration for the fusion pipeline.
    struct Config {
        /// Voxel size in meters. Smaller = denser output, more memory.
        var voxelSize: Float = 0.0005  // 0.5mm

        /// Minimum depth samples per voxel to emit a fused point.
        var minSamplesPerVoxel: Int = 2

        /// Depth pixel stride for unprojection (1 = every pixel).
        var unprojectionStride: Int = 1

        /// ROI mask radius in depth pixels.
        var roiMaskRadiusPixels: Int = 30

        /// Min valid depth (meters).
        var minDepth: Float = 0.10

        /// Max valid depth (meters).
        var maxDepth: Float = 0.60

        /// Bounding box padding around face ROI (meters).
        var boundsPadding: Float = 0.03  // 3cm

        static let `default` = Config()
    }

    /// Result of the fusion process.
    struct FusionResult {
        let fusedPoints: [VoxelGrid.FusedPoint]
        let framesProcessed: Int
        let totalRawPoints: Int
        let occupiedVoxels: Int
        let boundingBoxMin: SIMD3<Float>
        let boundingBoxMax: SIMD3<Float>
    }

    private let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    /// Fuse depth frames into a dense point cloud.
    ///
    /// - Parameters:
    ///   - depthBundles: Per-frame depth bundles from the scan session.
    ///   - faceVertices: ARKit face vertices (face-local space) for ROI estimation.
    /// - Returns: `FusionResult` with the fused point cloud.
    func fuse(
        depthBundles: [DepthBundle],
        faceVertices: [SIMD3<Float>]
    ) -> FusionResult {
        guard !depthBundles.isEmpty, !faceVertices.isEmpty else {
            return FusionResult(
                fusedPoints: [],
                framesProcessed: 0,
                totalRawPoints: 0,
                occupiedVoxels: 0,
                boundingBoxMin: .zero,
                boundingBoxMax: .zero
            )
        }

        // Estimate bounding box from face vertices + padding
        let (bbMin, bbMax) = computeBounds(vertices: faceVertices, padding: config.boundsPadding)

        let grid = VoxelGrid(boundsMin: bbMin, boundsMax: bbMax, voxelSize: config.voxelSize)

        var totalRaw = 0
        var framesProcessed = 0

        for bundle in depthBundles {
            // Build ROI mask for this frame
            let roiMask = DepthUnprojector.buildROIMask(
                faceVertices: faceVertices,
                bundle: bundle,
                radiusPixels: config.roiMaskRadiusPixels
            )

            // Unproject depth into face-local 3D points
            let points = DepthUnprojector.unproject(
                depthBuffer: bundle.depthMap,
                intrinsics: bundle.intrinsics,
                depthWidth: bundle.depthResolution.x,
                depthHeight: bundle.depthResolution.y,
                cameraTransform: bundle.cameraTransform,
                faceTransform: bundle.faceTransform,
                roiMask: roiMask,
                extrinsicMatrix: bundle.extrinsicMatrix,
                stride: config.unprojectionStride,
                minDepth: config.minDepth,
                maxDepth: config.maxDepth
            )

            grid.insertBatch(points: points)
            totalRaw += points.count
            framesProcessed += 1
        }

        let fused = grid.extract(minSamples: config.minSamplesPerVoxel)

        print("[PointCloudFusion] \(framesProcessed) frames, \(totalRaw) raw points -> \(fused.count) fused points (\(grid.occupiedCount()) occupied voxels)")

        return FusionResult(
            fusedPoints: fused,
            framesProcessed: framesProcessed,
            totalRawPoints: totalRaw,
            occupiedVoxels: grid.occupiedCount(),
            boundingBoxMin: bbMin,
            boundingBoxMax: bbMax
        )
    }

    // MARK: - Private

    private func computeBounds(
        vertices: [SIMD3<Float>],
        padding: Float
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        var minV = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)

        for v in vertices {
            minV = min(minV, v)
            maxV = max(maxV, v)
        }

        let pad = SIMD3<Float>(repeating: padding)
        return (minV - pad, maxV + pad)
    }
}
