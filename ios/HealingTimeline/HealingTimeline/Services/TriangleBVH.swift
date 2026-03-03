import Foundation
import simd

// MARK: - AABB

/// Axis-Aligned Bounding Box used for BVH nodes.
struct AABB {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    /// Signed distance from the point to the nearest box surface.
    /// Negative when inside.
    func distanceTo(_ point: SIMD3<Float>) -> Float {
        let clamped = simd_clamp(point, min, max)
        return length(clamped - point)
    }

    /// Smallest AABB enclosing both inputs.
    static func enclosing(_ a: AABB, _ b: AABB) -> AABB {
        AABB(
            min: simd_min(a.min, b.min),
            max: simd_max(a.max, b.max)
        )
    }

    /// AABB for a single triangle.
    static func fromTriangle(
        _ v0: SIMD3<Float>,
        _ v1: SIMD3<Float>,
        _ v2: SIMD3<Float>
    ) -> AABB {
        AABB(
            min: simd_min(simd_min(v0, v1), v2),
            max: simd_max(simd_max(v0, v1), v2)
        )
    }

    var center: SIMD3<Float> { (min + max) * 0.5 }
}

// MARK: - TriangleBVH

/// Bounding Volume Hierarchy for triangle meshes.
///
/// Accelerates closest-triangle queries from **O(n·m)** to **O(n·log m)**.
/// Uses a median-split construction strategy.
final class TriangleBVH {

    /// Query result: triangle index, barycentric coordinates, and distance.
    struct ClosestResult {
        let triangleIndex: Int
        let barycentricCoords: SIMD3<Float>
        let distance: Float
    }

    // ── Internal node storage (flat array) ──────────────────────────────

    private struct Node {
        let bounds: AABB
        /// `>= 0` means leaf, holding a single triangle index.
        /// `< 0` means internal; left child is at `leftChild`, right at `leftChild + 1`.
        let leafTriangleIndex: Int  // -1 for internal nodes
        let leftChild: Int          // index into `nodes` (internal only)
    }

    private var nodes: [Node] = []

    /// Original mesh data retained for distance queries.
    private let vertices: [SIMD3<Float>]
    private let indices: [UInt32]
    private let triCount: Int

    // MARK: - Build

    /// Build a BVH from a triangle mesh.
    ///
    /// - Complexity: O(n log n) where n = number of triangles.
    init(vertices: [SIMD3<Float>], indices: [UInt32]) {
        self.vertices = vertices
        self.indices = indices
        self.triCount = indices.count / 3

        // Pre-compute per-triangle AABB + centroid
        var triBoxes = [AABB]()
        var triCentroids = [SIMD3<Float>]()
        var triIndicesArr = [Int]()
        triBoxes.reserveCapacity(triCount)
        triCentroids.reserveCapacity(triCount)
        triIndicesArr.reserveCapacity(triCount)

        for t in 0..<triCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }

            let box = AABB.fromTriangle(vertices[i0], vertices[i1], vertices[i2])
            triBoxes.append(box)
            triCentroids.append(box.center)
            triIndicesArr.append(t)
        }

        // Reserve enough space (at most 2n-1 nodes for n leaves)
        nodes.reserveCapacity(triIndicesArr.count * 2)

        // Recursive build
        _ = buildRecursive(
            triIndices: &triIndicesArr,
            triBoxes: triBoxes,
            triCentroids: triCentroids,
            start: 0,
            end: triIndicesArr.count
        )
    }

    /// Recursive median-split BVH construction.
    /// Returns the index of the node created.
    @discardableResult
    private func buildRecursive(
        triIndices: inout [Int],
        triBoxes: [AABB],
        triCentroids: [SIMD3<Float>],
        start: Int,
        end: Int
    ) -> Int {
        let count = end - start

        if count == 1 {
            // Leaf node
            let t = triIndices[start]
            let nodeIdx = nodes.count
            nodes.append(Node(
                bounds: triBoxes[t],
                leafTriangleIndex: t,
                leftChild: -1
            ))
            return nodeIdx
        }

        // Compute enclosing AABB of centroids to pick split axis
        var centroidMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var centroidMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var enclosing = triBoxes[triIndices[start]]

        for i in start..<end {
            let t = triIndices[i]
            centroidMin = simd_min(centroidMin, triCentroids[t])
            centroidMax = simd_max(centroidMax, triCentroids[t])
            enclosing = AABB.enclosing(enclosing, triBoxes[t])
        }

        // Split along the longest axis of the centroid extent
        let extent = centroidMax - centroidMin
        let axis: Int
        if extent.x >= extent.y && extent.x >= extent.z { axis = 0 }
        else if extent.y >= extent.z { axis = 1 }
        else { axis = 2 }

        // Sort triangles by centroid on the chosen axis (median split)
        let mid = (start + end) / 2
        // Partial sort: partition around median
        triIndices[start..<end].sort { a, b in
            triCentroids[a][axis] < triCentroids[b][axis]
        }

        // Reserve a slot for this internal node
        let nodeIdx = nodes.count
        nodes.append(Node(bounds: enclosing, leafTriangleIndex: -1, leftChild: -1))

        // Recurse
        let leftIdx = buildRecursive(
            triIndices: &triIndices, triBoxes: triBoxes,
            triCentroids: triCentroids, start: start, end: mid
        )
        let rightIdx = buildRecursive(
            triIndices: &triIndices, triBoxes: triBoxes,
            triCentroids: triCentroids, start: mid, end: end
        )

        // Patch internal node
        nodes[nodeIdx] = Node(
            bounds: enclosing,
            leafTriangleIndex: -1,
            leftChild: leftIdx
        )
        // Right child is always leftIdx + subtree-size, but since we built
        // left first and then right, rightIdx is simply the next node after left's subtree.
        // We store leftChild; rightChild = leftChild + leftSubtreeSize.
        // For simplicity, store right child index directly using a helper array.
        // Actually, let's just store both children as a pair.
        // Since Swift structs are value types and we already appended, let's use
        // a side-band array for right children.
        rightChildren[nodeIdx] = rightIdx

        return nodeIdx
    }

    /// Side-band storage for right child indices.
    private var rightChildren = [Int: Int]()

    // MARK: - Query

    /// Find the closest triangle to a query point.
    ///
    /// - Complexity: O(log n) average case.
    func closestTriangle(to point: SIMD3<Float>) -> ClosestResult {
        var bestDist = Float.greatestFiniteMagnitude
        var bestTri = 0
        var bestBary = SIMD3<Float>(1, 0, 0)

        closestRecursive(
            nodeIdx: 0,
            point: point,
            bestDist: &bestDist,
            bestTri: &bestTri,
            bestBary: &bestBary
        )

        return ClosestResult(
            triangleIndex: bestTri,
            barycentricCoords: bestBary,
            distance: bestDist
        )
    }

    private func closestRecursive(
        nodeIdx: Int,
        point: SIMD3<Float>,
        bestDist: inout Float,
        bestTri: inout Int,
        bestBary: inout SIMD3<Float>
    ) {
        guard nodeIdx < nodes.count else { return }
        let node = nodes[nodeIdx]

        // Prune: if the AABB is farther than current best, skip
        let boxDist = node.bounds.distanceTo(point)
        guard boxDist < bestDist else { return }

        if node.leafTriangleIndex >= 0 {
            // Leaf: exact distance test
            let t = node.leafTriangleIndex
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { return }

            let (bary, dist) = BarycentricMapper.closestPointOnTriangle(
                point: point,
                v0: vertices[i0],
                v1: vertices[i1],
                v2: vertices[i2]
            )

            if dist < bestDist {
                bestDist = dist
                bestTri = t
                bestBary = bary
            }
            return
        }

        // Internal: visit children (nearer child first)
        let leftIdx = node.leftChild
        let rightIdx = rightChildren[nodeIdx] ?? (leftIdx + 1)

        let leftDist = leftIdx < nodes.count ? nodes[leftIdx].bounds.distanceTo(point) : Float.greatestFiniteMagnitude
        let rightDist = rightIdx < nodes.count ? nodes[rightIdx].bounds.distanceTo(point) : Float.greatestFiniteMagnitude

        if leftDist < rightDist {
            closestRecursive(nodeIdx: leftIdx, point: point, bestDist: &bestDist, bestTri: &bestTri, bestBary: &bestBary)
            closestRecursive(nodeIdx: rightIdx, point: point, bestDist: &bestDist, bestTri: &bestTri, bestBary: &bestBary)
        } else {
            closestRecursive(nodeIdx: rightIdx, point: point, bestDist: &bestDist, bestTri: &bestTri, bestBary: &bestBary)
            closestRecursive(nodeIdx: leftIdx, point: point, bestDist: &bestDist, bestTri: &bestTri, bestBary: &bestBary)
        }
    }
}
