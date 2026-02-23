import XCTest
@testable import HealingTimeline

final class HealingModelTests: XCTestCase {

    // MARK: - Swelling Tests

    func testSwellingPeakAtDayZero() {
        let model = HealingModel()
        let s = model.swelling(at: 0)
        XCTAssertGreaterThanOrEqual(s, 0.95, "Swelling at t=0 should be ~1.0")
        XCTAssertLessThanOrEqual(s, 1.0)
    }

    func testSwellingMonotoneDecrease() {
        let model = HealingModel()
        var prev = model.swelling(at: 0)
        for d in 1...365 {
            let curr = model.swelling(at: Float(d))
            XCTAssertLessThanOrEqual(curr, prev + 1e-6, "Swelling increased at day \(d)")
            prev = curr
        }
    }

    func testSwellingNearZeroAt365() {
        let model = HealingModel()
        let s = model.swelling(at: 365)
        XCTAssertLessThan(s, 0.05, "Swelling at 365 days should be < 5%")
    }

    func testSwellingRangeOrdered() {
        let model = HealingModel()
        for d: Float in [0, 7, 30, 90, 365] {
            let (sMin, sMed, sMax) = model.swellingRange(at: d)
            XCTAssertLessThanOrEqual(sMin, sMed)
            XCTAssertLessThanOrEqual(sMed, sMax)
        }
    }

    // MARK: - Bruising Tests

    func testBruisingZeroAtDayZero() {
        let model = HealingModel()
        XCTAssertEqual(model.bruising(at: 0), 0.0)
    }

    func testBruisingPeakNearDay2to3() {
        let model = HealingModel()
        var maxVal: Float = 0
        var peakDay: Float = 0
        for d in stride(from: Float(0), through: 7, by: 0.5) {
            let b = model.bruising(at: d)
            if b > maxVal { maxVal = b; peakDay = d }
        }
        XCTAssertGreaterThanOrEqual(peakDay, 1.5)
        XCTAssertLessThanOrEqual(peakDay, 4.0)
    }

    func testBruisingResolvedByDay14() {
        let model = HealingModel()
        let b = model.bruising(at: 14)
        XCTAssertLessThan(b, 0.1)
    }

    func testBruisingDisabled() {
        let profile = HealingProfile(bruisingPresent: false)
        let model = HealingModel(profile: profile)
        for d: Float in [0, 3, 7, 14] {
            XCTAssertEqual(model.bruising(at: d), 0.0)
        }
    }

    // MARK: - Color Tests

    func testBruiseColorValidRGB() {
        let model = HealingModel()
        for d in 0..<15 {
            let c = model.bruiseColor(at: Float(d))
            XCTAssertGreaterThanOrEqual(c.x, 0)
            XCTAssertLessThanOrEqual(c.x, 1)
            XCTAssertGreaterThanOrEqual(c.y, 0)
            XCTAssertLessThanOrEqual(c.y, 1)
            XCTAssertGreaterThanOrEqual(c.z, 0)
            XCTAssertLessThanOrEqual(c.z, 1)
        }
    }

    // MARK: - Volume Tests

    func testVolumePositive() {
        let model = HealingModel()
        for d: Float in [0, 1, 7, 30] {
            XCTAssertGreaterThanOrEqual(model.nasalVolumeDelta(at: d), 0)
        }
    }

    func testVolumeDecreases() {
        let model = HealingModel()
        var prev = model.nasalVolumeDelta(at: 0)
        for d in 1...365 {
            let curr = model.nasalVolumeDelta(at: Float(d))
            XCTAssertLessThanOrEqual(curr, prev + 1e-6)
            prev = curr
        }
    }

    // MARK: - Profile Effects

    func testThickSkinMoreSwelling() {
        let thin = HealingModel(profile: HealingProfile(skinThickness: .thin))
        let thick = HealingModel(profile: HealingProfile(skinThickness: .thick))
        XCTAssertGreaterThan(thick.swelling(at: 90), thin.swelling(at: 90))
    }

    func testHighIntensityMoreSwelling() {
        let low = HealingModel(profile: HealingProfile(initialIntensity: .low))
        let high = HealingModel(profile: HealingProfile(initialIntensity: .high))
        XCTAssertGreaterThan(high.swelling(at: 7), low.swelling(at: 7))
    }

    // MARK: - Mesh Tests

    func testSampleMeshGeneration() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        XCTAssertGreaterThan(mesh.vertexCount, 100)
        XCTAssertGreaterThan(mesh.triangleCount, 100)
        XCTAssertEqual(mesh.vertices.count, mesh.normals.count)
        XCTAssertEqual(mesh.vertices.count, mesh.zoneWeights.count)
    }

    func testMeshDisplacement() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let state = HealingState(
            day: 0,
            swellingLevel: 1.0,
            swellingMin: 0.65,
            swellingMax: 1.0,
            bruisingLevel: 0.5,
            bruiseColor: .init(0.4, 0.1, 0.3),
            nasalVolumeDelta: 4.0
        )
        let displaced = mesh.displaced(by: state)
        XCTAssertEqual(displaced.vertexCount, mesh.vertexCount)

        // At least some vertices should have moved
        var moved = 0
        for i in 0..<mesh.vertexCount {
            if mesh.vertices[i] != displaced.vertices[i] { moved += 1 }
        }
        XCTAssertGreaterThan(moved, 0, "No vertices were displaced")
    }

    // MARK: - Normal Computation

    func testComputeNormals() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let normals = MeshProcessor.computeNormals(
            vertices: mesh.vertices,
            indices: mesh.triangleIndices
        )
        XCTAssertEqual(normals.count, mesh.vertexCount)

        // All normals should be unit length
        for n in normals {
            let len = sqrt(n.x*n.x + n.y*n.y + n.z*n.z)
            XCTAssertEqual(len, 1.0, accuracy: 0.01)
        }
    }
}
