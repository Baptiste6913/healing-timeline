import Foundation
import simd
import ModelIO

/// Mesh processing utilities: normals, alignment, decimation, export.
enum MeshProcessor {

    // MARK: - Normal Computation

    /// Compute per-vertex normals from triangle mesh via area-weighted averaging.
    /// Ensures normals point outward (away from mesh centroid).
    static func computeNormals(vertices: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)

        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])

            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }

            let v0 = vertices[i0]
            let v1 = vertices[i1]
            let v2 = vertices[i2]

            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let faceNormal = cross(edge1, edge2) // area-weighted (not normalized)

            normals[i0] += faceNormal
            normals[i1] += faceNormal
            normals[i2] += faceNormal
        }

        // Compute centroid for outward-direction validation
        var centroid = SIMD3<Float>.zero
        for v in vertices { centroid += v }
        if !vertices.isEmpty { centroid /= Float(vertices.count) }

        // Normalize and ensure outward orientation
        var flippedCount = 0
        for i in 0..<normals.count {
            let len = length(normals[i])
            if len > 1e-8 {
                normals[i] = normals[i] / len
                // Validate outward direction: normal should point away from centroid
                let toVertex = vertices[i] - centroid
                if dot(normals[i], toVertex) < 0 {
                    normals[i] = -normals[i]
                    flippedCount += 1
                }
            } else {
                normals[i] = SIMD3<Float>(0, 0, 1)
            }
        }

        if flippedCount > 0 {
            print("[MeshProcessor] Flipped \(flippedCount)/\(normals.count) normals to ensure outward orientation")
        }

        return normals
    }

    // MARK: - Canonical Alignment

    /// Align mesh so nose tip is at origin, Y up.
    static func alignCanonical(mesh: inout FaceMeshData) {
        guard !mesh.vertices.isEmpty else { return }

        // Find centroid
        var centroid = SIMD3<Float>.zero
        for v in mesh.vertices {
            centroid += v
        }
        centroid /= Float(mesh.vertices.count)

        // Find foremost point (max Z) as nose tip proxy
        var noseTip = centroid
        var maxZ: Float = -.greatestFiniteMagnitude
        for v in mesh.vertices {
            if v.z > maxZ {
                maxZ = v.z
                noseTip = v
            }
        }

        // Translate so nose tip at origin
        let offset = noseTip
        for i in 0..<mesh.vertices.count {
            mesh.vertices[i] -= offset
        }
    }

    // MARK: - Mesh Decimation (simple vertex clustering)

    /// Reduce vertex count by clustering vertices in a grid.
    static func decimate(mesh: FaceMeshData, targetVertexCount: Int) -> FaceMeshData {
        guard mesh.vertexCount > targetVertexCount else { return mesh }

        // Simple uniform sampling - keep every Nth vertex
        let stride = max(1, mesh.vertexCount / targetVertexCount)
        var newVertices = [SIMD3<Float>]()
        var newNormals = [SIMD3<Float>]()
        var newWeights = [Float]()
        var indexMap = [Int: Int]() // old index -> new index

        for i in stride(from: 0, to: mesh.vertexCount, by: stride) {
            indexMap[i] = newVertices.count
            newVertices.append(mesh.vertices[i])
            newNormals.append(mesh.normals[i])
            newWeights.append(mesh.zoneWeights[i])
        }

        // Rebuild triangles (only keep triangles where all 3 vertices survive)
        var newIndices = [UInt32]()
        let triCount = mesh.triangleIndices.count / 3
        for t in 0..<triCount {
            let i0 = Int(mesh.triangleIndices[t * 3])
            let i1 = Int(mesh.triangleIndices[t * 3 + 1])
            let i2 = Int(mesh.triangleIndices[t * 3 + 2])

            if let n0 = indexMap[i0], let n1 = indexMap[i1], let n2 = indexMap[i2] {
                newIndices.append(UInt32(n0))
                newIndices.append(UInt32(n1))
                newIndices.append(UInt32(n2))
            }
        }

        return FaceMeshData(
            vertices: newVertices,
            normals: newNormals,
            triangleIndices: newIndices,
            textureCoordinates: nil,
            zoneWeights: newWeights,
            scanMode: mesh.scanMode,
            qualityMetrics: mesh.qualityMetrics
        )
    }

    // MARK: - OBJ Export

    /// Export mesh to OBJ format string.
    static func exportOBJ(mesh: FaceMeshData) -> String {
        var output = "# Healing Timeline - Face Mesh Export\n"
        output += "# Vertices: \(mesh.vertexCount), Triangles: \(mesh.triangleCount)\n\n"

        for v in mesh.vertices {
            output += "v \(v.x) \(v.y) \(v.z)\n"
        }
        output += "\n"

        for n in mesh.normals {
            output += "vn \(n.x) \(n.y) \(n.z)\n"
        }
        output += "\n"

        let triCount = mesh.triangleIndices.count / 3
        for t in 0..<triCount {
            let i0 = mesh.triangleIndices[t * 3] + 1  // OBJ is 1-indexed
            let i1 = mesh.triangleIndices[t * 3 + 1] + 1
            let i2 = mesh.triangleIndices[t * 3 + 2] + 1
            output += "f \(i0)//\(i0) \(i1)//\(i1) \(i2)//\(i2)\n"
        }

        return output
    }

    // MARK: - PLY Export

    /// Export mesh to PLY format string (binary-compatible ASCII variant).
    static func exportPLY(mesh: FaceMeshData) -> String {
        var output = "ply\n"
        output += "format ascii 1.0\n"
        output += "comment Healing Timeline - Face Mesh Export\n"
        output += "comment scanMode: \(mesh.scanMode.rawValue)\n"
        output += "comment isSampleMesh: \(mesh.isSampleMesh)\n"
        output += "element vertex \(mesh.vertexCount)\n"
        output += "property float x\n"
        output += "property float y\n"
        output += "property float z\n"
        output += "property float nx\n"
        output += "property float ny\n"
        output += "property float nz\n"
        output += "property float zone_weight\n"
        output += "element face \(mesh.triangleCount)\n"
        output += "property list uchar int vertex_indices\n"
        output += "end_header\n"

        for i in 0..<mesh.vertexCount {
            let v = mesh.vertices[i]
            let n = mesh.normals[i]
            let w = mesh.zoneWeights[i]
            output += "\(v.x) \(v.y) \(v.z) \(n.x) \(n.y) \(n.z) \(w)\n"
        }

        let triCount = mesh.triangleIndices.count / 3
        for t in 0..<triCount {
            let i0 = mesh.triangleIndices[t * 3]
            let i1 = mesh.triangleIndices[t * 3 + 1]
            let i2 = mesh.triangleIndices[t * 3 + 2]
            output += "3 \(i0) \(i1) \(i2)\n"
        }

        return output
    }

    // MARK: - Frame-to-Frame RMS

    /// Compute RMS distance between two sets of vertices (same topology assumed).
    /// Returns the RMS in meters.
    static func computeFrameRMS(
        previous: [SIMD3<Float>],
        current: [SIMD3<Float>]
    ) -> Float {
        guard previous.count == current.count, !previous.isEmpty else { return -1 }
        var sumSq: Float = 0
        for i in 0..<previous.count {
            let diff = current[i] - previous[i]
            sumSq += dot(diff, diff)
        }
        return sqrt(sumSq / Float(previous.count))
    }

    // MARK: - Trimmed-Mean Aggregation

    /// Aggregate a buffer of per-frame vertex arrays using a trimmed mean.
    ///
    /// For each vertex index, the coordinate values across all frames are sorted,
    /// the top/bottom `trimPercent` are removed, and the remainder is averaged.
    ///
    /// - Parameters:
    ///   - frameBuffer: Array of per-frame vertex positions (`[frame][vertex]`).
    ///   - vertexCount: Expected number of vertices per frame.
    ///   - trimPercent: Fraction to remove from each tail (e.g. 0.10 = 10%).
    /// - Returns: `(aggregated, framesUsed)` — the cleaned vertex array and how many
    ///   frames survived the consistency filter.
    static func trimmedMeanAggregate(
        frameBuffer: [[SIMD3<Float>]],
        vertexCount: Int,
        trimPercent: Float = 0.10
    ) -> (vertices: [SIMD3<Float>], framesUsed: Int) {
        // Keep only frames with the correct vertex count
        let validFrames = frameBuffer.filter { $0.count == vertexCount }
        let N = validFrames.count
        guard N >= 3 else {
            // Not enough frames — fallback to simple mean
            return (simpleMean(validFrames, vertexCount: vertexCount), max(N, 1))
        }

        let trimCount = max(1, Int(Float(N) * trimPercent))
        let keepRange = trimCount ..< (N - trimCount)
        let framesUsed = keepRange.count

        var result = [SIMD3<Float>](repeating: .zero, count: vertexCount)

        for vi in 0..<vertexCount {
            // Gather x/y/z across frames and sort independently
            var xs = [Float](), ys = [Float](), zs = [Float]()
            xs.reserveCapacity(N); ys.reserveCapacity(N); zs.reserveCapacity(N)

            for frame in validFrames {
                xs.append(frame[vi].x)
                ys.append(frame[vi].y)
                zs.append(frame[vi].z)
            }

            xs.sort(); ys.sort(); zs.sort()

            let trimmedX = xs[keepRange]
            let trimmedY = ys[keepRange]
            let trimmedZ = zs[keepRange]

            let scale = 1.0 / Float(framesUsed)
            result[vi] = SIMD3<Float>(
                trimmedX.reduce(0, +) * scale,
                trimmedY.reduce(0, +) * scale,
                trimmedZ.reduce(0, +) * scale
            )
        }

        return (result, framesUsed)
    }

    /// Simple mean fallback when there are too few frames for trimming.
    private static func simpleMean(
        _ frames: [[SIMD3<Float>]],
        vertexCount: Int
    ) -> [SIMD3<Float>] {
        guard !frames.isEmpty else { return [] }
        var result = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        for frame in frames {
            for i in 0..<min(vertexCount, frame.count) {
                result[i] += frame[i]
            }
        }
        let scale = 1.0 / Float(frames.count)
        for i in 0..<vertexCount {
            result[i] *= scale
        }
        return result
    }

    // MARK: - JSON Stats Export

    /// Save quality metrics as a JSON sidecar alongside mesh exports.
    @discardableResult
    static func saveStatsJSON(metrics: ScanQualityMetrics, filename: String) -> URL? {
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let jsonStr = metrics.jsonString() else {
            return nil
        }
        let url = docsDir.appendingPathComponent("\(filename)_stats.json")
        do {
            try jsonStr.write(to: url, atomically: true, encoding: .utf8)
            print("[MeshProcessor] Exported stats → \(url.lastPathComponent)")
            return url
        } catch {
            print("[MeshProcessor] Stats export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Mesh Export to Documents

    /// Save mesh to the app's Documents directory. Returns the file URL on success.
    @discardableResult
    static func saveMeshToDocuments(mesh: FaceMeshData, filename: String, format: MeshExportFormat) -> URL? {
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("[MeshProcessor] Could not access Documents directory")
            return nil
        }
        let content: String
        let ext: String
        switch format {
        case .obj:
            content = exportOBJ(mesh: mesh)
            ext = "obj"
        case .ply:
            content = exportPLY(mesh: mesh)
            ext = "ply"
        }
        let url = docsDir.appendingPathComponent("\(filename).\(ext)")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            print("[MeshProcessor] Exported \(ext.uppercased()) → \(url.lastPathComponent) (\(mesh.vertexCount)v, \(mesh.triangleCount)t)")
            return url
        } catch {
            print("[MeshProcessor] Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    enum MeshExportFormat {
        case obj, ply
    }

    // MARK: - Render Mesh OBJ Export (Surgeon-Grade)

    /// Export a dense render mesh to OBJ format string (with UVs if available).
    static func exportRenderOBJ(mesh: MeshPostProcess.RenderMeshData) -> String {
        var output = "# Healing Timeline - Surgeon-Grade Render Mesh Export\n"
        output += "# Vertices: \(mesh.vertices.count), Triangles: \(mesh.triangleIndices.count / 3)\n"
        if mesh.textureCoordinates != nil {
            output += "# UVs: \(mesh.textureCoordinates!.count)\n"
        }
        output += "\n"

        for v in mesh.vertices {
            output += "v \(v.x) \(v.y) \(v.z)\n"
        }
        output += "\n"

        for n in mesh.normals {
            output += "vn \(n.x) \(n.y) \(n.z)\n"
        }
        output += "\n"

        if let uvs = mesh.textureCoordinates {
            for uv in uvs {
                output += "vt \(uv.x) \(uv.y)\n"
            }
            output += "\n"

            // Faces with v/vt/vn
            let triCount = mesh.triangleIndices.count / 3
            for t in 0..<triCount {
                let i0 = Int(mesh.triangleIndices[t * 3]) + 1
                let i1 = Int(mesh.triangleIndices[t * 3 + 1]) + 1
                let i2 = Int(mesh.triangleIndices[t * 3 + 2]) + 1
                output += "f \(i0)/\(i0)/\(i0) \(i1)/\(i1)/\(i1) \(i2)/\(i2)/\(i2)\n"
            }
        } else {
            // Faces with v//vn
            let triCount = mesh.triangleIndices.count / 3
            for t in 0..<triCount {
                let i0 = Int(mesh.triangleIndices[t * 3]) + 1
                let i1 = Int(mesh.triangleIndices[t * 3 + 1]) + 1
                let i2 = Int(mesh.triangleIndices[t * 3 + 2]) + 1
                output += "f \(i0)//\(i0) \(i1)//\(i1) \(i2)//\(i2)\n"
            }
        }

        return output
    }

    // MARK: - Render Mesh PLY Export (Surgeon-Grade)

    /// Export a dense render mesh to PLY format string (with UVs if available).
    static func exportRenderPLY(mesh: MeshPostProcess.RenderMeshData) -> String {
        let hasUVs = mesh.textureCoordinates != nil

        var output = "ply\n"
        output += "format ascii 1.0\n"
        output += "comment Healing Timeline - Surgeon-Grade Render Mesh\n"
        output += "element vertex \(mesh.vertices.count)\n"
        output += "property float x\n"
        output += "property float y\n"
        output += "property float z\n"
        output += "property float nx\n"
        output += "property float ny\n"
        output += "property float nz\n"
        if hasUVs {
            output += "property float s\n"
            output += "property float t\n"
        }
        output += "element face \(mesh.triangleIndices.count / 3)\n"
        output += "property list uchar int vertex_indices\n"
        output += "end_header\n"

        for i in 0..<mesh.vertices.count {
            let v = mesh.vertices[i]
            let n = mesh.normals[i]
            if hasUVs, let uvs = mesh.textureCoordinates {
                let uv = uvs[i]
                output += "\(v.x) \(v.y) \(v.z) \(n.x) \(n.y) \(n.z) \(uv.x) \(uv.y)\n"
            } else {
                output += "\(v.x) \(v.y) \(v.z) \(n.x) \(n.y) \(n.z)\n"
            }
        }

        let triCount = mesh.triangleIndices.count / 3
        for t in 0..<triCount {
            let i0 = mesh.triangleIndices[t * 3]
            let i1 = mesh.triangleIndices[t * 3 + 1]
            let i2 = mesh.triangleIndices[t * 3 + 2]
            output += "3 \(i0) \(i1) \(i2)\n"
        }

        return output
    }

    // MARK: - Render Mesh File Export

    /// Save render mesh to Documents directory. Returns file URL on success.
    @discardableResult
    static func saveRenderMeshToDocuments(
        mesh: MeshPostProcess.RenderMeshData,
        filename: String,
        format: MeshExportFormat
    ) -> URL? {
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("[MeshProcessor] Could not access Documents directory")
            return nil
        }
        let content: String
        let ext: String
        switch format {
        case .obj:
            content = exportRenderOBJ(mesh: mesh)
            ext = "obj"
        case .ply:
            content = exportRenderPLY(mesh: mesh)
            ext = "ply"
        }
        let url = docsDir.appendingPathComponent("\(filename)_render.\(ext)")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            print("[MeshProcessor] Exported render \(ext.uppercased()) → \(url.lastPathComponent) (\(mesh.vertices.count)v, \(mesh.triangleIndices.count / 3)t)")
            return url
        } catch {
            print("[MeshProcessor] Render export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Texture Atlas PNG Export

    /// Export a baked texture atlas as a PNG file.
    ///
    /// Converts the linear-space float data to 8-bit sRGB PNG.
    /// - Parameters:
    ///   - atlas: The bake result containing linear RGB texel data.
    ///   - filename: Base filename (without extension).
    /// - Returns: File URL on success, `nil` on failure.
    @discardableResult
    static func exportTextureAtlas(_ atlas: TextureBaker.BakeResult, filename: String) -> URL? {
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("[MeshProcessor] Could not access Documents directory")
            return nil
        }

        let w = atlas.atlasWidth
        let h = atlas.atlasHeight
        let bytesPerRow = w * 4

        guard let context = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("[MeshProcessor] Atlas PNG: failed to create CGContext")
            return nil
        }

        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        for y in 0..<h {
            for x in 0..<w {
                let srcIdx = y * w + x
                let dstIdx = y * bytesPerRow + x * 4
                let texel = atlas.textureData[srcIdx]
                // linear → sRGB for PNG display
                pixels[dstIdx + 0] = UInt8(clamping: Int(linearToSRGB(texel.x) * 255))
                pixels[dstIdx + 1] = UInt8(clamping: Int(linearToSRGB(texel.y) * 255))
                pixels[dstIdx + 2] = UInt8(clamping: Int(linearToSRGB(texel.z) * 255))
                pixels[dstIdx + 3] = 255
            }
        }

        guard let cgImage = context.makeImage() else {
            print("[MeshProcessor] Atlas PNG: failed to create CGImage")
            return nil
        }

        let url = docsDir.appendingPathComponent("\(filename)_atlas.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            print("[MeshProcessor] Atlas PNG: failed to create image destination")
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)

        if CGImageDestinationFinalize(dest) {
            print("[MeshProcessor] Exported atlas PNG → \(url.lastPathComponent) (\(w)×\(h), \(String(format: "%.1f", atlas.coverage * 100))% coverage)")
            return url
        } else {
            print("[MeshProcessor] Atlas PNG: finalize failed")
            return nil
        }
    }

    /// Convert linear [0,1] to sRGB [0,1].
    private static func linearToSRGB(_ c: Float) -> Float {
        if c <= 0.0031308 {
            return c * 12.92
        } else {
            return 1.055 * pow(c, 1.0 / 2.4) - 0.055
        }
    }

    // MARK: - Bruise Mask (CPU-side for Export)

    /// Generate a CPU-side bruise mask image for export.
    ///
    /// This is NOT used at runtime (bruise overlay is Metal-only) — it exists
    /// solely for exporting a visual representation alongside the atlas PNG.
    ///
    /// - Parameters:
    ///   - atlasSize: Width and height of the mask.
    ///   - bruiseLevel: Bruise intensity (0-1).
    ///   - bruiseColor: RGB bruise color in linear space.
    /// - Returns: Raw RGBA pixel data as `[UInt8]`, or `nil` on failure.
    static func generateBruiseMask(
        atlasSize: Int,
        bruiseLevel: Float,
        bruiseColor: SIMD3<Float>
    ) -> [UInt8]? {
        guard bruiseLevel > 0.01 else { return nil }

        let count = atlasSize * atlasSize * 4
        var pixels = [UInt8](repeating: 0, count: count)

        for y in 0..<atlasSize {
            for x in 0..<atlasSize {
                let u = Float(x) / Float(atlasSize)
                let v = Float(y) / Float(atlasSize)

                // Spatial falloff — approximate zone (center = nose)
                let cx: Float = 0.5, cy: Float = 0.45
                let dist = sqrt((u - cx) * (u - cx) + (v - cy) * (v - cy))
                let zoneFalloff = max(0, 1.0 - dist / 0.35)
                let blendFactor = bruiseLevel * zoneFalloff

                let idx = (y * atlasSize + x) * 4
                pixels[idx + 0] = UInt8(clamping: Int(linearToSRGB(bruiseColor.x * blendFactor) * 255))
                pixels[idx + 1] = UInt8(clamping: Int(linearToSRGB(bruiseColor.y * blendFactor) * 255))
                pixels[idx + 2] = UInt8(clamping: Int(linearToSRGB(bruiseColor.z * blendFactor) * 255))
                pixels[idx + 3] = UInt8(clamping: Int(blendFactor * 255))  // alpha = intensity
            }
        }

        return pixels
    }

    /// Export bruise mask as a PNG file.
    @discardableResult
    static func exportBruiseMask(
        atlasSize: Int,
        bruiseLevel: Float,
        bruiseColor: SIMD3<Float>,
        filename: String
    ) -> URL? {
        guard let pixels = generateBruiseMask(atlasSize: atlasSize, bruiseLevel: bruiseLevel, bruiseColor: bruiseColor) else {
            return nil
        }
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }

        let bytesPerRow = atlasSize * 4
        var mutablePixels = pixels

        guard let context = CGContext(
            data: &mutablePixels,
            width: atlasSize,
            height: atlasSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            return nil
        }

        let url = docsDir.appendingPathComponent("\(filename)_bruise_mask.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    // MARK: - Mapping Binary Export

    /// Export a barycentric mapping to binary data and save to disk.
    ///
    /// Uses PropertyList binary format via `BarycentricMapper.serialize()`.
    @discardableResult
    static func exportMapping(_ mapper: BarycentricMapper, filename: String) -> URL? {
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }

        let data = mapper.serialize()
        guard !data.isEmpty else {
            print("[MeshProcessor] Mapping serialization produced empty data")
            return nil
        }

        let url = docsDir.appendingPathComponent("\(filename)_mapping.bin")
        do {
            try data.write(to: url, options: .atomic)
            print("[MeshProcessor] Exported mapping binary → \(url.lastPathComponent) (\(data.count) bytes, \(mapper.mappings.count) entries)")
            return url
        } catch {
            print("[MeshProcessor] Mapping export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Surgeon-Grade Export Stats

    /// Comprehensive statistics JSON for a surgeon-grade export.
    ///
    /// Encapsulates all pipeline diagnostics in a single `Codable` struct.
    struct SurgeonGradeExportStats: Codable {
        // Canonical mesh
        let canonicalVertexCount: Int
        let canonicalTriangleCount: Int
        let scanMode: String

        // Render mesh
        let renderVertexCount: Int
        let renderTriangleCount: Int
        let hasTextureCoordinates: Bool

        // MC diagnostics
        let mcTriangles: Int
        let mcDegenerateCulled: Int
        let mcNaNRejected: Int
        let mcComponents: Int
        let mcBoundaryEdges: Int
        let mcNormalOutwardRatio: Float
        let mcAmbiguousCasesResolved: Int
        let mcTetrahedraFallbacks: Int
        let mcPassesSurgeonGrade: Bool

        // Texture
        let textureCoverage: Float
        let textureAtlasSize: Int
        let textureFramesUsed: Int
        let atlasHash: UInt64

        // Mapping
        let mappingEntryCount: Int
        let identityMaxErrorMM: Float

        // Quality gate thresholds (for reproducibility)
        let gateMinNormalOutwardRatio: Float
        let gateMaxBoundaryEdgeRatio: Float
        let gateMinMCTriangles: Int
        let gateMaxIdentityErrorMM: Float
        let gateMinTextureCoverage: Float

        // Timing
        let phaseTimings: [String: Double]

        // Overall
        let pipelineSucceeded: Bool
        let failReason: String?

        /// Create from pipeline result + canonical mesh info.
        init(
            canonical: FaceMeshData,
            pipelineResult: DenseScanPipeline.PipelineResult,
            identityMaxErrorMM: Float
        ) {
            self.canonicalVertexCount = canonical.vertexCount
            self.canonicalTriangleCount = canonical.triangleCount
            self.scanMode = canonical.scanMode.rawValue

            self.renderVertexCount = pipelineResult.renderMesh?.vertices.count ?? 0
            self.renderTriangleCount = (pipelineResult.renderMesh?.triangleIndices.count ?? 0) / 3
            self.hasTextureCoordinates = pipelineResult.renderMesh?.textureCoordinates != nil

            // MC diagnostics — zero if pipeline failed before Phase 3
            self.mcTriangles = 0
            self.mcDegenerateCulled = 0
            self.mcNaNRejected = 0
            self.mcComponents = 0
            self.mcBoundaryEdges = 0
            self.mcNormalOutwardRatio = 0
            self.mcAmbiguousCasesResolved = 0
            self.mcTetrahedraFallbacks = 0
            self.mcPassesSurgeonGrade = pipelineResult.succeeded

            self.textureCoverage = pipelineResult.textureAtlas?.coverage ?? 0
            self.textureAtlasSize = pipelineResult.textureAtlas?.atlasWidth ?? 0
            self.textureFramesUsed = pipelineResult.textureAtlas?.framesUsed ?? 0
            self.atlasHash = pipelineResult.textureAtlas?.atlasHash ?? 0

            self.mappingEntryCount = pipelineResult.barycentricMapper?.mappings.count ?? 0
            self.identityMaxErrorMM = identityMaxErrorMM

            self.gateMinNormalOutwardRatio = SurgeonGradeQualityGate.minNormalOutwardRatio
            self.gateMaxBoundaryEdgeRatio = SurgeonGradeQualityGate.maxBoundaryEdgeRatio
            self.gateMinMCTriangles = SurgeonGradeQualityGate.minMCTriangles
            self.gateMaxIdentityErrorMM = SurgeonGradeQualityGate.maxIdentityErrorM * 1000
            self.gateMinTextureCoverage = SurgeonGradeQualityGate.minTextureCoverage

            self.phaseTimings = pipelineResult.phaseTimings
            self.pipelineSucceeded = pipelineResult.succeeded
            self.failReason = pipelineResult.failReason
        }

        /// Create with explicit MC diagnostics.
        init(
            canonical: FaceMeshData,
            pipelineResult: DenseScanPipeline.PipelineResult,
            mcDiagnostics: MCDiagnostics?,
            identityMaxErrorMM: Float
        ) {
            self.canonicalVertexCount = canonical.vertexCount
            self.canonicalTriangleCount = canonical.triangleCount
            self.scanMode = canonical.scanMode.rawValue

            self.renderVertexCount = pipelineResult.renderMesh?.vertices.count ?? 0
            self.renderTriangleCount = (pipelineResult.renderMesh?.triangleIndices.count ?? 0) / 3
            self.hasTextureCoordinates = pipelineResult.renderMesh?.textureCoordinates != nil

            self.mcTriangles = mcDiagnostics?.numTriangles ?? 0
            self.mcDegenerateCulled = mcDiagnostics?.numDegenerateCulled ?? 0
            self.mcNaNRejected = mcDiagnostics?.numNaNRejected ?? 0
            self.mcComponents = mcDiagnostics?.numComponents ?? 0
            self.mcBoundaryEdges = mcDiagnostics?.boundaryEdgesCount ?? 0
            self.mcNormalOutwardRatio = mcDiagnostics?.normalOutwardRatio ?? 0
            self.mcAmbiguousCasesResolved = mcDiagnostics?.ambiguousCasesResolved ?? 0
            self.mcTetrahedraFallbacks = mcDiagnostics?.tetrahedraFallbacks ?? 0
            self.mcPassesSurgeonGrade = mcDiagnostics?.passesSurgeonGrade ?? false

            self.textureCoverage = pipelineResult.textureAtlas?.coverage ?? 0
            self.textureAtlasSize = pipelineResult.textureAtlas?.atlasWidth ?? 0
            self.textureFramesUsed = pipelineResult.textureAtlas?.framesUsed ?? 0
            self.atlasHash = pipelineResult.textureAtlas?.atlasHash ?? 0

            self.mappingEntryCount = pipelineResult.barycentricMapper?.mappings.count ?? 0
            self.identityMaxErrorMM = identityMaxErrorMM

            self.gateMinNormalOutwardRatio = SurgeonGradeQualityGate.minNormalOutwardRatio
            self.gateMaxBoundaryEdgeRatio = SurgeonGradeQualityGate.maxBoundaryEdgeRatio
            self.gateMinMCTriangles = SurgeonGradeQualityGate.minMCTriangles
            self.gateMaxIdentityErrorMM = SurgeonGradeQualityGate.maxIdentityErrorM * 1000
            self.gateMinTextureCoverage = SurgeonGradeQualityGate.minTextureCoverage

            self.phaseTimings = pipelineResult.phaseTimings
            self.pipelineSucceeded = pipelineResult.succeeded
            self.failReason = pipelineResult.failReason
        }

        /// Serialize to pretty-printed JSON.
        func jsonString() -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// Export surgeon-grade stats JSON to Documents directory.
    @discardableResult
    static func exportSurgeonGradeStats(_ stats: SurgeonGradeExportStats, filename: String) -> URL? {
        guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let json = stats.jsonString() else {
            return nil
        }
        let url = docsDir.appendingPathComponent("\(filename)_surgeon_grade_stats.json")
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            print("[MeshProcessor] Exported surgeon-grade stats → \(url.lastPathComponent)")
            return url
        } catch {
            print("[MeshProcessor] Stats export failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - USDZ Export via ModelIO

    /// Export mesh to a USDZ file at the given URL.
    static func exportUSDZ(mesh: FaceMeshData, to url: URL) throws {
        let allocator = MDLMeshBufferDataAllocator()

        // Vertex buffer
        let vertexData = Data(bytes: mesh.vertices, count: mesh.vertices.count * MemoryLayout<SIMD3<Float>>.stride)
        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)

        // Index buffer
        let indexData = Data(bytes: mesh.triangleIndices, count: mesh.triangleIndices.count * MemoryLayout<UInt32>.stride)
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: mesh.triangleIndices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )

        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

        let mdlMesh = MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: mesh.vertices.count,
            descriptor: vertexDescriptor,
            submeshes: [submesh]
        )

        let asset = MDLAsset()
        asset.add(mdlMesh)

        try asset.export(to: url)
    }
}
