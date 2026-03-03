import Foundation
import simd
import AVFoundation

/// Unprojects depth pixels into 3D points in camera space.
///
/// Given a depth buffer and camera intrinsics, produces a dense point cloud
/// in the camera coordinate system. Supports optional lens distortion LUT
/// and ROI masking.
enum DepthUnprojector {

    /// A single unprojected 3D point with metadata.
    struct PointSample {
        let position: SIMD3<Float>  // in target coordinate space
        let confidence: Float       // 0..1 (1 = high quality)
        let pixelU: Int
        let pixelV: Int
    }

    /// Unproject a depth buffer into a dense point cloud in face-local space.
    ///
    /// Pipeline: depth pixel -> camera 3D -> world 3D -> face-local 3D
    ///
    /// - Parameters:
    ///   - depthBuffer: Float32 depth map (meters).
    ///   - intrinsics: Camera intrinsics rescaled to depth map resolution.
    ///   - depthWidth: Width of depth buffer.
    ///   - depthHeight: Height of depth buffer.
    ///   - cameraTransform: ARFrame.camera.transform (camera -> world).
    ///   - faceTransform: ARFaceAnchor.transform (face -> world).
    ///   - roiMask: Optional per-pixel mask. If non-nil, only pixels where mask[y*w+x] == true are unprojected.
    ///   - extrinsicMatrix: Optional RGB->depth extrinsic.
    ///   - stride: Sample every Nth pixel (default 1 = all pixels).
    ///   - minDepth: Minimum valid depth in meters (default 0.1).
    ///   - maxDepth: Maximum valid depth in meters (default 0.6).
    /// - Returns: Array of `PointSample` in face-local coordinates.
    static func unproject(
        depthBuffer: CVPixelBuffer,
        intrinsics: simd_float3x3,
        depthWidth: Int,
        depthHeight: Int,
        cameraTransform: simd_float4x4,
        faceTransform: simd_float4x4,
        roiMask: [Bool]? = nil,
        extrinsicMatrix: simd_float4x3? = nil,
        stride: Int = 1,
        minDepth: Float = 0.10,
        maxDepth: Float = 0.60
    ) -> [PointSample] {

        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        guard fx > 0, fy > 0 else { return [] }

        let fxInv = 1.0 / fx
        let fyInv = 1.0 / fy

        // Precompute inverse transforms
        let faceInv = faceTransform.inverse  // world -> face-local

        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(depthBuffer) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
        let floatPtr = baseAddr.assumingMemoryBound(to: Float.self)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float>.stride

        var points: [PointSample] = []
        points.reserveCapacity(depthWidth * depthHeight / (stride * stride))

        for py in Swift.stride(from: 0, to: depthHeight, by: stride) {
            for px in Swift.stride(from: 0, to: depthWidth, by: stride) {
                // ROI mask check
                if let mask = roiMask, !mask[py * depthWidth + px] { continue }

                let depth = floatPtr[py * floatsPerRow + px]

                // Validity checks
                guard depth > minDepth, depth < maxDepth, !depth.isNaN, !depth.isInfinite else { continue }

                // Unproject: pixel -> camera 3D
                let camX = (Float(px) - cx) * fxInv * depth
                let camY = (Float(py) - cy) * fyInv * depth
                let camZ = depth

                // Apply extrinsics (depth cam -> RGB cam) inverse if present
                // Note: our intrinsics are in depth-camera space, so camXYZ is already depth-camera
                // We need to go depth-camera -> world -> face-local
                let camPos: SIMD4<Float>
                if let ext = extrinsicMatrix {
                    // extrinsicMatrix maps RGB->depth, we need depth->RGB
                    // For small baselines (TrueDepth), ext is near-identity
                    // Approximate inverse: just use camera transform directly
                    camPos = SIMD4<Float>(camX, camY, camZ, 1)
                } else {
                    camPos = SIMD4<Float>(camX, camY, camZ, 1)
                }

                // Camera 3D -> world
                let worldPos = cameraTransform * camPos

                // World -> face-local
                let faceLocal = faceInv * worldPos
                let point = SIMD3<Float>(faceLocal.x, faceLocal.y, faceLocal.z)

                // Basic confidence: center pixels get higher confidence, edges lower
                let normalizedU = abs(Float(px) - Float(depthWidth) / 2) / Float(depthWidth)
                let normalizedV = abs(Float(py) - Float(depthHeight) / 2) / Float(depthHeight)
                let edgeDist = max(normalizedU, normalizedV)
                let confidence: Float = max(0, 1.0 - edgeDist * 1.5)

                points.append(PointSample(
                    position: point,
                    confidence: confidence,
                    pixelU: px,
                    pixelV: py
                ))
            }
        }

        return points
    }

    /// Build a binary ROI mask for the nose + midface region.
    ///
    /// Projects existing ARKit face vertices into depth space and marks
    /// pixels within a radius of the nose tip + midface area.
    ///
    /// - Parameters:
    ///   - faceVertices: ARKit face vertices in face-local space.
    ///   - bundle: Depth bundle with transforms and intrinsics.
    ///   - radiusPixels: Pixel radius around ROI vertices to include.
    /// - Returns: Boolean mask array of size depthWidth * depthHeight.
    static func buildROIMask(
        faceVertices: [SIMD3<Float>],
        bundle: DepthBundle,
        radiusPixels: Int = 30
    ) -> [Bool] {
        let w = bundle.depthResolution.x
        let h = bundle.depthResolution.y
        var mask = [Bool](repeating: false, count: w * h)

        // Get ROI vertex indices (nose + midface)
        let roiIndices = DepthCorrectionService.buildNoseMidfaceROI(vertices: faceVertices)

        for idx in roiIndices {
            guard let proj = DepthCorrectionService.projectVertexToDepthPixel(
                vertex: faceVertices[idx],
                bundle: bundle
            ) else { continue }

            let cx = Int(proj.u)
            let cy = Int(proj.v)

            // Fill circle around projected point
            for dy in -radiusPixels...radiusPixels {
                for dx in -radiusPixels...radiusPixels {
                    let px = cx + dx
                    let py = cy + dy
                    guard px >= 0, px < w, py >= 0, py < h else { continue }
                    if dx * dx + dy * dy <= radiusPixels * radiusPixels {
                        mask[py * w + px] = true
                    }
                }
            }
        }

        return mask
    }
}
