import Foundation
import simd
import AVFoundation
import CoreVideo

/// Multi-view texture baking for the dense ROI render mesh.
///
/// Projects camera frames onto the mesh UV space, blending contributions
/// from multiple views weighted by viewing angle and distance.
enum TextureBaker {

    /// A captured camera frame for texture baking.
    struct CameraFrame {
        let pixelBuffer: CVPixelBuffer      // RGB camera image
        let cameraTransform: simd_float4x4  // camera -> world
        let faceTransform: simd_float4x4    // face -> world
        let intrinsics: simd_float3x3       // camera intrinsics
        let imageWidth: Int
        let imageHeight: Int
        let timestamp: TimeInterval
    }

    /// Configuration for texture baking.
    struct Config {
        /// Texture atlas resolution (width and height).
        var atlasSize: Int = 1024

        /// Minimum viewing angle cosine to accept a frame's contribution.
        /// Cos(60deg) = 0.5, cos(45deg) = 0.707
        var minViewAngleCos: Float = 0.3

        /// Maximum distance from camera to surface (meters).
        var maxDistance: Float = 0.5

        /// Number of best frames to blend per texel.
        var maxFramesPerTexel: Int = 4

        static let `default` = Config()
    }

    /// Result of texture baking.
    struct BakeResult {
        let textureData: [SIMD3<Float>]     // Linear-space RGB per texel, row-major
        let atlasWidth: Int
        let atlasHeight: Int
        let coverage: Float                 // fraction of texels with data
        let framesUsed: Int
        /// FNV-1a hash of the raw textureData bytes.  Used to verify the
        /// base atlas has never been mutated (non-negotiable: bruise overlay
        /// must be a Metal shader, NOT a CPU rebake).
        let atlasHash: UInt64

        /// Verify that textureData has not been modified since baking.
        func verifyIntegrity() -> Bool {
            return TextureBaker.computeAtlasHash(textureData) == atlasHash
        }
    }

    // MARK: - Atlas Hash (FNV-1a)

    /// Compute a 64-bit FNV-1a hash over the raw float bytes of an atlas.
    static func computeAtlasHash(_ data: [SIMD3<Float>]) -> UInt64 {
        var hash: UInt64 = 14695981039346656037          // FNV offset basis
        let prime: UInt64 = 1099511628211                // FNV prime
        data.withUnsafeBufferPointer { buffer in
            let rawBuffer = UnsafeRawBufferPointer(buffer)
            for byte in rawBuffer {
                hash ^= UInt64(byte)
                hash &*= prime
            }
        }
        return hash
    }

    // MARK: - sRGB ↔ Linear

    /// Convert a single sRGB [0,1] component to linear [0,1].
    static func sRGBToLinear(_ s: Float) -> Float {
        if s <= 0.04045 {
            return s / 12.92
        } else {
            return pow((s + 0.055) / 1.055, 2.4)
        }
    }

    /// Bake a multi-view texture atlas for a mesh.
    ///
    /// - Parameters:
    ///   - vertices: Mesh vertices (face-local space).
    ///   - normals: Per-vertex normals.
    ///   - uvs: Per-vertex UV coordinates [0, 1].
    ///   - triangleIndices: Triangle indices.
    ///   - frames: Camera frames captured during scan.
    ///   - config: Baking configuration.
    /// - Returns: `BakeResult` with the texture atlas.
    static func bake(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        uvs: [SIMD2<Float>],
        triangleIndices: [UInt32],
        frames: [CameraFrame],
        config: Config = .default
    ) -> BakeResult {
        let size = config.atlasSize
        var atlas = [SIMD3<Float>](repeating: .zero, count: size * size)
        var weights = [Float](repeating: 0, count: size * size)

        var framesUsed = 0

        for frame in frames {
            let faceInv = frame.faceTransform.inverse
            let cameraInFace = faceInv * frame.cameraTransform
            let cameraPos = SIMD3<Float>(
                cameraInFace.columns.3.x,
                cameraInFace.columns.3.y,
                cameraInFace.columns.3.z
            )
            let cameraForward = normalize(SIMD3<Float>(
                -cameraInFace.columns.2.x,
                -cameraInFace.columns.2.y,
                -cameraInFace.columns.2.z
            ))

            var frameContributed = false

            // For each triangle, rasterize in UV space
            let triCount = triangleIndices.count / 3
            for t in 0..<triCount {
                let i0 = Int(triangleIndices[t * 3])
                let i1 = Int(triangleIndices[t * 3 + 1])
                let i2 = Int(triangleIndices[t * 3 + 2])

                guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }

                // Triangle centroid for view angle check
                let centroid = (vertices[i0] + vertices[i1] + vertices[i2]) / 3
                let avgNormal = normalize(normals[i0] + normals[i1] + normals[i2])

                // View direction from surface to camera
                let viewDir = normalize(cameraPos - centroid)
                let viewAngleCos = dot(viewDir, avgNormal)

                guard viewAngleCos > config.minViewAngleCos else { continue }

                let dist = length(cameraPos - centroid)
                guard dist < config.maxDistance else { continue }

                // Weight: prefer frontal views at closer distance
                let weight = viewAngleCos / max(0.1, dist)

                // UV coordinates of triangle vertices
                let uv0 = uvs[i0]
                let uv1 = uvs[i1]
                let uv2 = uvs[i2]

                // Bounding box in texel space
                let minU = Int(floor(min(uv0.x, min(uv1.x, uv2.x)) * Float(size)))
                let maxU = Int(ceil(max(uv0.x, max(uv1.x, uv2.x)) * Float(size)))
                let minV = Int(floor(min(uv0.y, min(uv1.y, uv2.y)) * Float(size)))
                let maxV = Int(ceil(max(uv0.y, max(uv1.y, uv2.y)) * Float(size)))

                for ty in max(0, minV)..<min(size, maxV + 1) {
                    for tx in max(0, minU)..<min(size, maxU + 1) {
                        let texelUV = SIMD2<Float>(
                            (Float(tx) + 0.5) / Float(size),
                            (Float(ty) + 0.5) / Float(size)
                        )

                        // Barycentric test
                        guard let bary = barycentric(texelUV, uv0, uv1, uv2) else { continue }
                        guard bary.x >= 0, bary.y >= 0, bary.z >= 0 else { continue }

                        // Interpolate 3D position
                        let worldPos = vertices[i0] * bary.x + vertices[i1] * bary.y + vertices[i2] * bary.z

                        // Project to camera image
                        let cameraInv = frame.cameraTransform.inverse
                        let faceToWorld = frame.faceTransform
                        let worldPt = faceToWorld * SIMD4<Float>(worldPos, 1)
                        let camPt = cameraInv * worldPt

                        guard camPt.z > 0.01 else { continue }

                        let fx = frame.intrinsics[0][0]
                        let fy = frame.intrinsics[1][1]
                        let cx = frame.intrinsics[2][0]
                        let cy = frame.intrinsics[2][1]

                        let px = fx * (camPt.x / camPt.z) + cx
                        let py = fy * (camPt.y / camPt.z) + cy

                        let ipx = Int(px)
                        let ipy = Int(py)

                        guard ipx >= 0, ipx < frame.imageWidth,
                              ipy >= 0, ipy < frame.imageHeight else { continue }

                        // Sample pixel color from camera frame
                        if let color = samplePixel(frame.pixelBuffer, x: ipx, y: ipy) {
                            let idx = ty * size + tx
                            atlas[idx] += color * weight
                            weights[idx] += weight
                            frameContributed = true
                        }
                    }
                }
            }

            if frameContributed { framesUsed += 1 }
        }

        // Normalize by total weight
        var coveredTexels = 0
        for i in 0..<(size * size) {
            if weights[i] > 0 {
                atlas[i] /= weights[i]
                coveredTexels += 1
            } else {
                atlas[i] = SIMD3<Float>(0.85, 0.72, 0.62) // default skin color
            }
        }

        let coverage = Float(coveredTexels) / Float(size * size)

        print("[TextureBaker] \(framesUsed) frames, \(String(format: "%.1f", coverage * 100))% coverage")

        let hash = computeAtlasHash(atlas)

        return BakeResult(
            textureData: atlas,
            atlasWidth: size,
            atlasHeight: size,
            coverage: coverage,
            framesUsed: framesUsed,
            atlasHash: hash
        )
    }

    // MARK: - Private

    /// Compute barycentric coordinates of point p in triangle (a, b, c) in 2D.
    private static func barycentric(
        _ p: SIMD2<Float>,
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        _ c: SIMD2<Float>
    ) -> SIMD3<Float>? {
        let v0 = c - a
        let v1 = b - a
        let v2 = p - a

        let dot00 = dot(v0, v0)
        let dot01 = dot(v0, v1)
        let dot02 = dot(v0, v2)
        let dot11 = dot(v1, v1)
        let dot12 = dot(v1, v2)

        let denom = dot00 * dot11 - dot01 * dot01
        guard abs(denom) > 1e-10 else { return nil }

        let invDenom = 1.0 / denom
        let u = (dot11 * dot02 - dot01 * dot12) * invDenom
        let v = (dot00 * dot12 - dot01 * dot02) * invDenom
        let w = 1.0 - u - v

        return SIMD3<Float>(w, v, u)
    }

    /// Sample a single pixel from a CVPixelBuffer as normalized RGB.
    private static func samplePixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> SIMD3<Float>? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)

        // Handle common BGRA format — convert sRGB → linear at ingestion
        if format == kCVPixelFormatType_32BGRA {
            let ptr = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
            let b = sRGBToLinear(Float(ptr[0]) / 255.0)
            let g = sRGBToLinear(Float(ptr[1]) / 255.0)
            let r = sRGBToLinear(Float(ptr[2]) / 255.0)
            return SIMD3<Float>(r, g, b)
        }

        return nil
    }
}
