import Foundation
import simd
import ModelIO

/// Mesh processing utilities: normals, alignment, decimation, export.
enum MeshProcessor {

    // MARK: - Normal Computation

    /// Compute per-vertex normals from triangle mesh via area-weighted averaging.
    static func computeNormals(vertices: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)

        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])

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

        // Normalize
        for i in 0..<normals.count {
            let len = length(normals[i])
            if len > 1e-8 {
                normals[i] = normals[i] / len
            } else {
                normals[i] = SIMD3<Float>(0, 0, 1)
            }
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
            zoneWeights: newWeights
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
