import Foundation
import simd

/// Orchestrates the full surgeon-grade hybrid scan pipeline.
///
/// Called after ARKit frame aggregation completes. Runs through:
/// Phase 2: Dense point cloud fusion
/// Phase 3: TSDF meshing + composition
/// Phase 4: Multi-view texture baking
/// Phase 5: Barycentric mapping setup
///
/// Falls back to COARSE-STABLE mode if any gate fails.
enum DenseScanPipeline {

    /// Result of the full pipeline.
    struct PipelineResult {
        let renderMesh: MeshPostProcess.RenderMeshData?
        let barycentricMapper: BarycentricMapper?
        let textureAtlas: TextureBaker.BakeResult?
        let coverage: DenseROIBuilder.CoverageMetrics?
        let succeeded: Bool
        let failReason: String?
        let phaseTimings: [String: TimeInterval]  // phase name -> seconds
    }

    /// Run the complete surgeon-grade pipeline.
    ///
    /// - Parameters:
    ///   - canonicalVertices: Aggregated ARKit face vertices (face-local).
    ///   - canonicalNormals: Per-vertex normals.
    ///   - canonicalIndices: Triangle indices.
    ///   - depthBundles: All captured depth bundles.
    ///   - cameraFrames: Captured camera frames for texture baking.
    ///   - faceTransforms: Per-frame face transforms.
    ///   - cameraTransforms: Per-frame camera transforms.
    /// - Returns: `PipelineResult` with render mesh or fallback info.
    static func run(
        canonicalVertices: [SIMD3<Float>],
        canonicalNormals: [SIMD3<Float>],
        canonicalIndices: [UInt32],
        depthBundles: [DepthBundle],
        cameraFrames: [TextureBaker.CameraFrame],
        faceTransforms: [simd_float4x4],
        cameraTransforms: [simd_float4x4]
    ) -> PipelineResult {

        var timings: [String: TimeInterval] = [:]
        let pipelineStart = Date()

        // ── Phase 2: Dense Point Cloud ROI ───────────────────────────────
        let phase2Start = Date()

        let fusionConfig = PointCloudFusion.Config(
            voxelSize: FeatureFlags.tsdfVoxelSize,
            minSamplesPerVoxel: FeatureFlags.fusionMinSamplesPerVoxel,
            unprojectionStride: 1,
            roiMaskRadiusPixels: 30,
            minDepth: 0.10,
            maxDepth: 0.60,
            boundsPadding: 0.03
        )

        let roiResult = DenseROIBuilder.build(
            depthBundles: depthBundles,
            faceVertices: canonicalVertices,
            faceTransforms: faceTransforms,
            cameraTransforms: cameraTransforms,
            config: fusionConfig
        )

        timings["phase2_pointcloud"] = Date().timeIntervalSince(phase2Start)

        guard roiResult.passed else {
            print("[DensePipeline] FALLBACK at Phase 2: \(roiResult.failReason ?? "unknown")")
            return PipelineResult(
                renderMesh: nil,
                barycentricMapper: nil,
                textureAtlas: nil,
                coverage: roiResult.coverage,
                succeeded: false,
                failReason: "Phase 2 (Point Cloud): \(roiResult.failReason ?? "unknown")",
                phaseTimings: timings
            )
        }

        // ── Phase 3: TSDF Meshing ────────────────────────────────────────
        let phase3Start = Date()

        let fusedPositions = roiResult.fusedPoints.map { $0.position }
        let fusedNormals = MeshPostProcess.estimateNormals(points: fusedPositions, k: 8)

        // Create TSDF volume
        let tsdf = TSDFVolume(
            boundsMin: roiResult.boundingBoxMin,
            boundsMax: roiResult.boundingBoxMax,
            voxelSize: FeatureFlags.tsdfVoxelSize
        )

        tsdf.integrate(points: fusedPositions, normals: fusedNormals)

        // Extract mesh via marching cubes (hardened: ambiguity + diagnostics)
        let mcMesh = MarchingCubes.extract(from: tsdf, isoLevel: 0, minWeight: 0.5)

        timings["phase3_tsdf_meshing"] = Date().timeIntervalSince(phase3Start)

        // ── MC quality gate (surgeon-grade v1) ──────────────────────────
        if let diag = mcMesh.diagnostics, !diag.passesSurgeonGrade {
            let reason = diag.failReason ?? "unknown MC gate failure"
            print("[DensePipeline] FALLBACK at Phase 3: \(reason)")
            return PipelineResult(
                renderMesh: nil,
                barycentricMapper: nil,
                textureAtlas: nil,
                coverage: roiResult.coverage,
                succeeded: false,
                failReason: "Phase 3 (MC gate): \(reason)",
                phaseTimings: timings
            )
        }

        guard mcMesh.vertexCount >= 100 else {
            print("[DensePipeline] FALLBACK at Phase 3: marching cubes produced \(mcMesh.vertexCount) vertices")
            return PipelineResult(
                renderMesh: nil,
                barycentricMapper: nil,
                textureAtlas: nil,
                coverage: roiResult.coverage,
                succeeded: false,
                failReason: "Phase 3 (TSDF): only \(mcMesh.vertexCount) mesh vertices",
                phaseTimings: timings
            )
        }

        // Compose: canonical + dense ROI
        let noseTipIdx = DepthCorrectionService.findNoseTipIndex(vertices: canonicalVertices)
        let roiCenter = canonicalVertices[noseTipIdx]

        let composed = MeshPostProcess.compose(
            canonical: FaceMeshData(
                vertices: canonicalVertices,
                normals: canonicalNormals,
                triangleIndices: canonicalIndices,
                textureCoordinates: nil,
                zoneWeights: [] // not needed for render mesh
            ),
            denseROIMesh: mcMesh,
            roiCenter: roiCenter
        )

        print("[DensePipeline] Phase 3 complete: \(composed.render.vertices.count) render vertices, \(composed.render.triangleCount) triangles")

        // ── Phase 4: UV Unwrap + Texture Baking ─────────────────────────
        let phase4Start = Date()

        let uvs = UVUnwrapper.cylindricalUnwrap(
            vertices: composed.render.vertices,
            center: roiCenter
        )

        var textureAtlas: TextureBaker.BakeResult? = nil
        if !cameraFrames.isEmpty {
            let bakeConfig = TextureBaker.Config(
                atlasSize: FeatureFlags.textureAtlasSize,
                minViewAngleCos: 0.3,
                maxDistance: 0.5,
                maxFramesPerTexel: 4
            )
            textureAtlas = TextureBaker.bake(
                vertices: composed.render.vertices,
                normals: composed.render.normals,
                uvs: uvs,
                triangleIndices: composed.render.triangleIndices,
                frames: cameraFrames,
                config: bakeConfig
            )
        }

        timings["phase4_texture"] = Date().timeIntervalSince(phase4Start)

        // ── Phase 5: Barycentric Mapping ─────────────────────────────────
        let phase5Start = Date()

        let mapper = BarycentricMapper(
            renderVertices: composed.render.vertices,
            canonicalVertices: canonicalVertices,
            canonicalIndices: canonicalIndices
        )

        timings["phase5_mapping"] = Date().timeIntervalSince(phase5Start)

        // Verify mapping: identity deformation should produce ~zero displacement
        let identityTransfer = mapper.transfer(
            deformedCanonical: canonicalVertices,
            canonicalIndices: canonicalIndices
        )
        var maxIdentityError: Float = 0
        for i in 0..<min(composed.render.vertices.count, identityTransfer.count) {
            let err = length(identityTransfer[i] - composed.render.vertices[i])
            maxIdentityError = max(maxIdentityError, err)
        }

        if maxIdentityError > 0.005 {  // 5mm tolerance
            print("[DensePipeline] WARNING: identity mapping max error \(String(format: "%.3f", maxIdentityError * 1000))mm")
        }

        // Build final render mesh with UVs
        var finalRender = composed.render
        finalRender.textureCoordinates = uvs

        let totalTime = Date().timeIntervalSince(pipelineStart)
        timings["total"] = totalTime

        print("[DensePipeline] COMPLETE in \(String(format: "%.2f", totalTime))s: \(finalRender.vertices.count)v render, identity err \(String(format: "%.3f", maxIdentityError * 1000))mm")

        return PipelineResult(
            renderMesh: finalRender,
            barycentricMapper: mapper,
            textureAtlas: textureAtlas,
            coverage: roiResult.coverage,
            succeeded: true,
            failReason: nil,
            phaseTimings: timings
        )
    }
}

// MARK: - RenderMeshData helpers

extension MeshPostProcess.RenderMeshData {
    var vertexCount: Int { vertices.count }
    var triangleCount: Int { triangleIndices.count / 3 }
}
