import Foundation
import simd

/// Generates a procedural sample face mesh for testing/demo mode.
/// No real patient data is used.
enum SampleMeshLoader {

    /// Generate an ellipsoidal head mesh with nose bump.
    static func loadSampleMesh() -> FaceMeshData {
        let nLat = 30
        let nLon = 40
        let rx: Float = 0.08
        let ry: Float = 0.10
        let rz: Float = 0.09

        var vertices = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var zoneWeights = [Float]()

        for i in 0...nLat {
            let theta = Float.pi * Float(i) / Float(nLat)
            for j in 0..<nLon {
                let phi = 2 * Float.pi * Float(j) / Float(nLon)

                var x = rx * sin(theta) * cos(phi)
                var y = ry * sin(theta) * sin(phi)
                let z = rz * cos(theta)

                // Nose bump
                let noseTheta = Float.pi / 2
                let dTheta = theta - noseTheta
                var dPhi = phi
                if dPhi > Float.pi { dPhi -= 2 * Float.pi }

                let noseWidth: Float = 0.3
                let noseHeight: Float = 0.5
                let noseAmount: Float = 0.03
                let noseFactor = exp(-(dPhi / noseWidth) * (dPhi / noseWidth) - (dTheta / noseHeight) * (dTheta / noseHeight))
                let tipFactor = exp(-(dPhi / 0.15) * (dPhi / 0.15) - ((dTheta - 0.15) / 0.15) * ((dTheta - 0.15) / 0.15))

                x += (noseFactor * 0.7 + tipFactor * 0.3) * noseAmount * cos(phi)

                vertices.append(SIMD3<Float>(x, z, y)) // reorder to Y-up

                // Normal (approximate)
                let nx = x / (rx * rx)
                let ny = z / (rz * rz)
                let nz = y / (ry * ry)
                let len = sqrt(nx*nx + ny*ny + nz*nz)
                normals.append(len > 0 ? SIMD3<Float>(nx/len, ny/len, nz/len) : SIMD3<Float>(0, 1, 0))

                // Zone weights
                var weight: Float = 0
                if tipFactor > 0.5 { weight = 1.0 }
                else if noseFactor > 0.5 && dTheta < 0 { weight = 0.7 }
                else if noseFactor > 0.3 && abs(dPhi) > 0.1 { weight = 0.5 }
                else if abs(dTheta + 0.3) < 0.25 && abs(abs(dPhi) - 0.35) < 0.2 { weight = 0.4 }
                else if abs(dTheta) < 0.5 && abs(dPhi) < 0.8 { weight = 0.2 }
                zoneWeights.append(weight)
            }
        }

        // Triangles
        var indices = [UInt32]()
        for i in 0..<nLat {
            for j in 0..<nLon {
                let p0 = UInt32(i * nLon + j)
                let p1 = UInt32(i * nLon + (j + 1) % nLon)
                let p2 = UInt32((i + 1) * nLon + j)
                let p3 = UInt32((i + 1) * nLon + (j + 1) % nLon)
                indices.append(contentsOf: [p0, p2, p1])
                indices.append(contentsOf: [p1, p2, p3])
            }
        }

        return FaceMeshData(
            vertices: vertices,
            normals: normals,
            triangleIndices: indices,
            textureCoordinates: nil,
            zoneWeights: zoneWeights
        )
    }
}
