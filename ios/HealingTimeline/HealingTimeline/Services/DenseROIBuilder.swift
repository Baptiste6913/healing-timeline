import Foundation
import simd

/// Orchestrates the dense ROI point cloud construction pipeline.
///
/// Wraps DepthUnprojector + VoxelGrid + PointCloudFusion into a single
/// entry point, with quality gates and coverage metrics.
enum DenseROIBuilder {

    /// Coverage metrics for the dense ROI scan.
    struct CoverageMetrics {
        let yawCoverageDeg: Float       // estimated horizontal coverage
        let pitchCoverageDeg: Float     // estimated vertical coverage
        let coverageScore: Float        // 0..1 composite score
        let fusedPointCount: Int
        let depthFramesUsed: Int
        let rawPointsTotal: Int
        let voxelOccupancy: Float       // fraction of bounding box voxels occupied

        /// Whether coverage is sufficient for dense mesh reconstruction.
        var isSufficient: Bool { coverageScore >= 0.50 }
    }

    /// Result of the dense ROI build.
    struct BuildResult {
        let fusedPoints: [VoxelGrid.FusedPoint]
        let coverage: CoverageMetrics
        let boundingBoxMin: SIMD3<Float>
        let boundingBoxMax: SIMD3<Float>
        let passed: Bool                    // whether quality gates pass
        let failReason: String?
    }

    /// Build a dense point cloud of the nose + midface ROI from scan data.
    ///
    /// - Parameters:
    ///   - depthBundles: All depth bundles from the scan session.
    ///   - faceVertices: Final aggregated face vertices (face-local space).
    ///   - faceTransforms: Per-frame face transforms.
    ///   - cameraTransforms: Per-frame camera transforms.
    ///   - config: Fusion configuration (optional).
    /// - Returns: `BuildResult` with fused point cloud and metrics.
    static func build(
        depthBundles: [DepthBundle],
        faceVertices: [SIMD3<Float>],
        faceTransforms: [simd_float4x4],
        cameraTransforms: [simd_float4x4],
        config: PointCloudFusion.Config = .default
    ) -> BuildResult {

        // Gate: need depth data
        guard !depthBundles.isEmpty else {
            return BuildResult(
                fusedPoints: [],
                coverage: emptyCoverage(),
                boundingBoxMin: .zero,
                boundingBoxMax: .zero,
                passed: false,
                failReason: "No depth bundles available"
            )
        }

        guard !faceVertices.isEmpty else {
            return BuildResult(
                fusedPoints: [],
                coverage: emptyCoverage(),
                boundingBoxMin: .zero,
                boundingBoxMax: .zero,
                passed: false,
                failReason: "No face vertices available"
            )
        }

        // Run fusion
        let fusion = PointCloudFusion(config: config)
        let result = fusion.fuse(depthBundles: depthBundles, faceVertices: faceVertices)

        // Compute coverage metrics
        let coverage = computeCoverage(
            fusionResult: result,
            faceTransforms: faceTransforms,
            cameraTransforms: cameraTransforms
        )

        // Gate: minimum fused points
        let minFusedPoints = 500
        if result.fusedPoints.count < minFusedPoints {
            print("[DenseROI] FAILED: only \(result.fusedPoints.count) fused points (need \(minFusedPoints))")
            return BuildResult(
                fusedPoints: result.fusedPoints,
                coverage: coverage,
                boundingBoxMin: result.boundingBoxMin,
                boundingBoxMax: result.boundingBoxMax,
                passed: false,
                failReason: "Insufficient fused points: \(result.fusedPoints.count) < \(minFusedPoints)"
            )
        }

        // Gate: coverage score
        if !coverage.isSufficient {
            print("[DenseROI] FAILED: coverage score \(String(format: "%.2f", coverage.coverageScore)) < 0.50")
            return BuildResult(
                fusedPoints: result.fusedPoints,
                coverage: coverage,
                boundingBoxMin: result.boundingBoxMin,
                boundingBoxMax: result.boundingBoxMax,
                passed: false,
                failReason: "Insufficient coverage: \(String(format: "%.0f", coverage.coverageScore * 100))%"
            )
        }

        print("[DenseROI] PASSED: \(result.fusedPoints.count) points, coverage \(String(format: "%.0f", coverage.coverageScore * 100))%")

        return BuildResult(
            fusedPoints: result.fusedPoints,
            coverage: coverage,
            boundingBoxMin: result.boundingBoxMin,
            boundingBoxMax: result.boundingBoxMax,
            passed: true,
            failReason: nil
        )
    }

    // MARK: - Coverage Estimation

    private static func computeCoverage(
        fusionResult: PointCloudFusion.FusionResult,
        faceTransforms: [simd_float4x4],
        cameraTransforms: [simd_float4x4]
    ) -> CoverageMetrics {

        // Estimate yaw/pitch coverage from camera-to-face relative orientations
        let (yaw, pitch) = estimateAngularCoverage(
            faceTransforms: faceTransforms,
            cameraTransforms: cameraTransforms
        )

        // Voxel occupancy
        let totalVoxels = max(1, (fusionResult.boundingBoxMax - fusionResult.boundingBoxMin))
        let volumeEst = totalVoxels.x * totalVoxels.y * totalVoxels.z
        let voxelOccupancy: Float
        if volumeEst > 0 && fusionResult.occupiedVoxels > 0 {
            // Rough occupancy estimate
            voxelOccupancy = min(1.0, Float(fusionResult.occupiedVoxels) / max(1, Float(fusionResult.fusedPoints.count) * 2))
        } else {
            voxelOccupancy = 0
        }

        // Composite score: weighted combination
        let pointScore = min(1.0, Float(fusionResult.fusedPoints.count) / 5000.0)
        let frameScore = min(1.0, Float(fusionResult.framesProcessed) / 20.0)
        let coverageScore = pointScore * 0.5 + frameScore * 0.3 + min(1.0, yaw / 30.0) * 0.2

        return CoverageMetrics(
            yawCoverageDeg: yaw,
            pitchCoverageDeg: pitch,
            coverageScore: min(1.0, coverageScore),
            fusedPointCount: fusionResult.fusedPoints.count,
            depthFramesUsed: fusionResult.framesProcessed,
            rawPointsTotal: fusionResult.totalRawPoints,
            voxelOccupancy: voxelOccupancy
        )
    }

    private static func estimateAngularCoverage(
        faceTransforms: [simd_float4x4],
        cameraTransforms: [simd_float4x4]
    ) -> (yawDeg: Float, pitchDeg: Float) {
        guard faceTransforms.count >= 2 else { return (0, 0) }

        var yaws: [Float] = []
        var pitches: [Float] = []

        for i in 0..<min(faceTransforms.count, cameraTransforms.count) {
            let faceInv = faceTransforms[i].inverse
            let relative = faceInv * cameraTransforms[i]

            // Extract yaw/pitch from relative transform
            let forward = SIMD3<Float>(relative.columns.2.x, relative.columns.2.y, relative.columns.2.z)
            let yaw = atan2(forward.x, forward.z) * 180 / Float.pi
            let pitch = asin(max(-1, min(1, -forward.y))) * 180 / Float.pi

            yaws.append(yaw)
            pitches.append(pitch)
        }

        let yawRange = (yaws.max() ?? 0) - (yaws.min() ?? 0)
        let pitchRange = (pitches.max() ?? 0) - (pitches.min() ?? 0)

        return (yawRange, pitchRange)
    }

    private static func emptyCoverage() -> CoverageMetrics {
        CoverageMetrics(
            yawCoverageDeg: 0,
            pitchCoverageDeg: 0,
            coverageScore: 0,
            fusedPointCount: 0,
            depthFramesUsed: 0,
            rawPointsTotal: 0,
            voxelOccupancy: 0
        )
    }
}
