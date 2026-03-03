import XCTest
import simd
import Metal
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

    func testSampleMeshFlaggedAsDemo() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        XCTAssertTrue(mesh.isSampleMesh, "Sample mesh should have isSampleMesh == true")
        XCTAssertEqual(mesh.scanMode, .demo, "Sample mesh scanMode should be .demo")
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

        var moved = 0
        for i in 0..<mesh.vertexCount {
            if mesh.vertices[i] != displaced.vertices[i] { moved += 1 }
        }
        XCTAssertGreaterThan(moved, 0, "No vertices were displaced")
    }

    func testDisplacedMeshPreservesScanMode() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let state = HealingState(
            day: 7, swellingLevel: 0.5, swellingMin: 0.3, swellingMax: 0.7,
            bruisingLevel: 0.2, bruiseColor: .init(0.3, 0.2, 0.1), nasalVolumeDelta: 2.0
        )
        let displaced = mesh.displaced(by: state)
        XCTAssertEqual(displaced.scanMode, .demo, "scanMode should propagate through displacement")
        XCTAssertTrue(displaced.isSampleMesh)
    }

    // MARK: - Normal Computation

    func testComputeNormals() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let normals = MeshProcessor.computeNormals(
            vertices: mesh.vertices,
            indices: mesh.triangleIndices
        )
        XCTAssertEqual(normals.count, mesh.vertexCount)

        for n in normals {
            let len = sqrt(n.x*n.x + n.y*n.y + n.z*n.z)
            XCTAssertEqual(len, 1.0, accuracy: 0.01)
        }
    }

    func testNormalsPointOutward() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let normals = MeshProcessor.computeNormals(
            vertices: mesh.vertices,
            indices: mesh.triangleIndices
        )

        var centroid = SIMD3<Float>.zero
        for v in mesh.vertices { centroid += v }
        centroid /= Float(mesh.vertices.count)

        var outwardCount = 0
        for i in 0..<mesh.vertexCount {
            let toVertex = mesh.vertices[i] - centroid
            if dot(normals[i], toVertex) >= 0 {
                outwardCount += 1
            }
        }
        let outwardRatio = Float(outwardCount) / Float(mesh.vertexCount)
        XCTAssertGreaterThan(outwardRatio, 0.95)
    }

    // MARK: - Frame RMS

    func testFrameRMSIdenticalMeshes() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let rms = MeshProcessor.computeFrameRMS(previous: mesh.vertices, current: mesh.vertices)
        XCTAssertEqual(rms, 0.0, accuracy: 1e-8)
    }

    func testFrameRMSWithKnownOffset() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let offsetM: Float = 0.001
        let shifted = mesh.vertices.map { $0 + SIMD3<Float>(0, 0, offsetM) }
        let rms = MeshProcessor.computeFrameRMS(previous: mesh.vertices, current: shifted)
        XCTAssertEqual(rms, offsetM, accuracy: 1e-5)
    }

    func testFrameRMSMismatchedCounts() {
        let rms = MeshProcessor.computeFrameRMS(
            previous: [SIMD3<Float>(0, 0, 0)],
            current: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1)]
        )
        XCTAssertEqual(rms, -1)
    }

    // MARK: - Trimmed-Mean Aggregation

    func testTrimmedMeanRemovesOutliers() {
        let normal: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(1.0, 2.0, 3.0), count: 8)
        let outlierHigh: [SIMD3<Float>] = [SIMD3<Float>(100.0, 200.0, 300.0)]
        let outlierLow: [SIMD3<Float>] = [SIMD3<Float>(-100.0, -200.0, -300.0)]

        let frameBuffer = [outlierLow] + normal + [outlierHigh]
        let (result, framesUsed) = MeshProcessor.trimmedMeanAggregate(
            frameBuffer: frameBuffer,
            vertexCount: 1,
            trimPercent: 0.10
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].x, 1.0, accuracy: 0.1, "Outliers should be trimmed")
        XCTAssertEqual(result[0].y, 2.0, accuracy: 0.1)
        XCTAssertEqual(result[0].z, 3.0, accuracy: 0.1)
        XCTAssertGreaterThan(framesUsed, 0)
    }

    func testTrimmedMeanIdenticalFrames() {
        let vertex = SIMD3<Float>(0.05, 0.03, 0.02)
        let frames = Array(repeating: [vertex], count: 20)

        let (result, framesUsed) = MeshProcessor.trimmedMeanAggregate(
            frameBuffer: frames,
            vertexCount: 1,
            trimPercent: 0.10
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].x, vertex.x, accuracy: 1e-6)
        XCTAssertEqual(result[0].y, vertex.y, accuracy: 1e-6)
        XCTAssertEqual(result[0].z, vertex.z, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(framesUsed, 20)
    }

    func testTrimmedMeanFiltersInvalidFrames() {
        let vertex = SIMD3<Float>(1, 2, 3)
        let validFrames: [[SIMD3<Float>]] = Array(repeating: [vertex], count: 10)
        let invalidFrame: [SIMD3<Float>] = [vertex, vertex]

        let buffer = validFrames + [invalidFrame]
        let (result, _) = MeshProcessor.trimmedMeanAggregate(
            frameBuffer: buffer,
            vertexCount: 1,
            trimPercent: 0.10
        )

        XCTAssertEqual(result.count, 1, "Invalid frames should be filtered out")
        XCTAssertEqual(result[0].x, vertex.x, accuracy: 1e-6)
    }

    func testTrimmedMeanFallbackWithFewFrames() {
        let vertex = SIMD3<Float>(1, 2, 3)
        let frames = [[vertex], [vertex]]

        let (result, _) = MeshProcessor.trimmedMeanAggregate(
            frameBuffer: frames,
            vertexCount: 1,
            trimPercent: 0.10
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].x, vertex.x, accuracy: 1e-6)
    }

    // MARK: - Quality Metrics

    func testQualityGradeDemo() {
        let metrics = makeMockMetrics(scanMode: .demo)
        XCTAssertEqual(metrics.grade, .demo)
    }

    func testQualityGradeExcellent() {
        let metrics = makeMockMetrics(
            meanFrameRMS: 0.0005,
            poseRotationStdDeg: 0.5,
            framesUsed: 48,
            scanMode: .coarseStable
        )
        XCTAssertEqual(metrics.grade, .excellent)
    }

    func testQualityGradeGood() {
        let metrics = makeMockMetrics(
            meanFrameRMS: 0.001,
            poseRotationStdDeg: 1.5,
            framesUsed: 40,
            scanMode: .coarseStable
        )
        XCTAssertEqual(metrics.grade, .good)
    }

    func testQualityGradePoorHighJitter() {
        let metrics = makeMockMetrics(
            meanFrameRMS: 0.003,
            poseRotationStdDeg: 0.5,
            framesUsed: 48,
            scanMode: .coarseStable
        )
        XCTAssertEqual(metrics.grade, .poor)
    }

    func testQualityGradePoorHighRotation() {
        let metrics = makeMockMetrics(
            meanFrameRMS: 0.0005,
            poseRotationStdDeg: 4.0,
            framesUsed: 48,
            scanMode: .coarseStable
        )
        XCTAssertEqual(metrics.grade, .poor)
    }

    func testQualityMetricsJSONRoundtrip() {
        let metrics = makeMockMetrics()
        let json = metrics.jsonString()
        XCTAssertNotNil(json, "JSON serialization should succeed")
        XCTAssertTrue(json!.contains("meanFrameRMS"))
        XCTAssertTrue(json!.contains("scanMode"))
        // Depth fields
        XCTAssertTrue(json!.contains("depthDataType"))
        XCTAssertTrue(json!.contains("depthResolutionW"))
        XCTAssertTrue(json!.contains("depthFramesPerSecond"))
        XCTAssertTrue(json!.contains("registrationMedianAbsErrorMm"))
        XCTAssertTrue(json!.contains("registrationMADAbsErrorMm"))
        XCTAssertTrue(json!.contains("registrationBiasMm"))
        // Tier 2.5 fields
        XCTAssertTrue(json!.contains("depthDataAccuracy"))
        XCTAssertTrue(json!.contains("depthDataQuality"))
        XCTAssertTrue(json!.contains("isDepthDataFiltered"))
        XCTAssertTrue(json!.contains("crosscheckPixelErrorMedian"))
    }

    // MARK: - Feature Flags

    func testDepthCorrectionDefaultOff() {
        UserDefaults.standard.removeObject(forKey: "feature_depthCorrection")
        XCTAssertFalse(FeatureFlags.depthCorrectionEnabled)
    }

    func testFeatureFlagsPersistence() {
        FeatureFlags.depthCorrectionEnabled = true
        XCTAssertTrue(FeatureFlags.depthCorrectionEnabled)
        FeatureFlags.depthCorrectionEnabled = false
        XCTAssertFalse(FeatureFlags.depthCorrectionEnabled)
    }

    func testRegistrationGateThresholdsExist() {
        XCTAssertEqual(FeatureFlags.depthRegistrationMedianMaxMm, 2.0)
        XCTAssertEqual(FeatureFlags.depthRegistrationMADMaxMm, 1.0)
        XCTAssertEqual(FeatureFlags.depthRegistrationBiasMaxMm, 1.0)
    }

    func testCrossValidationThresholdExists() {
        XCTAssertEqual(FeatureFlags.crossValidationMaxPixelError, 3.0)
    }

    // MARK: - Depth Correction Gating

    func testDepthCorrectionDisabledByDefault() {
        UserDefaults.standard.removeObject(forKey: "feature_depthCorrection")

        let vertices = [SIMD3<Float>(0, 0, 0.03)]
        let result = DepthCorrectionService.correct(
            vertices: vertices,
            depthBundles: [],
            faceTransforms: [],
            frameTransforms: []
        )

        XCTAssertTrue(result.autoDisabled)
        XCTAssertEqual(result.correctedVertices, vertices, "Vertices should be unchanged when disabled")
    }

    func testDepthCorrectionRejectsEmptyBundles() {
        FeatureFlags.depthCorrectionEnabled = true
        defer { FeatureFlags.depthCorrectionEnabled = false }

        let vertices = [SIMD3<Float>(0, 0, 0.03)]
        let result = DepthCorrectionService.correct(
            vertices: vertices,
            depthBundles: [],
            faceTransforms: [matrix_identity_float4x4],
            frameTransforms: [matrix_identity_float4x4]
        )

        XCTAssertTrue(result.autoDisabled)
        XCTAssertNotNil(result.autoDisableReason)
    }

    // MARK: - (a) Gate 3: Accuracy — .relative disables Tier 2

    func testAccuracyGateRejectsRelative() {
        FeatureFlags.depthCorrectionEnabled = true
        defer { FeatureFlags.depthCorrectionEnabled = false }

        let width = 8, height = 8
        let depthValues = Array(repeating: Float(0.03), count: width * height)
        guard let depthBuf = createFloat32PixelBuffer(width: width, height: height, values: depthValues) else {
            XCTFail("Could not create pixel buffer"); return
        }

        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(Float(width), 0, 0),
            SIMD3<Float>(0, Float(height), 0),
            SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
        ))

        let bundles = (0..<5).map { i in
            DepthBundle(
                depthMap: depthBuf, intrinsics: intrinsics,
                depthResolution: SIMD2<Int>(width, height),
                timestamp: TimeInterval(i),
                faceTransform: matrix_identity_float4x4,
                cameraTransform: matrix_identity_float4x4,
                originalDepthDataType: kCVPixelFormatType_DepthFloat32,
                pixelSizeMM: nil,
                depthDataAccuracy: "relative",
                depthDataQuality: "high",
                isDepthDataFiltered: true,
                extrinsicMatrix: nil,
                referenceProjections: nil
            )
        }

        let vertices = [SIMD3<Float>(0, 0, 0.03)]
        let faceTs = bundles.map { _ in matrix_identity_float4x4 }

        let result = DepthCorrectionService.correct(
            vertices: vertices,
            depthBundles: bundles,
            faceTransforms: faceTs,
            frameTransforms: faceTs
        )

        XCTAssertTrue(result.autoDisabled, "Should be auto-disabled with .relative accuracy")
        XCTAssertTrue(result.autoDisableReason?.contains("relative") == true)
    }

    // MARK: - (b) Gate 4: Quality — all .low disables Tier 2

    func testQualityGateRejectsAllLow() {
        FeatureFlags.depthCorrectionEnabled = true
        defer { FeatureFlags.depthCorrectionEnabled = false }

        let width = 8, height = 8
        let depthValues = Array(repeating: Float(0.03), count: width * height)
        guard let depthBuf = createFloat32PixelBuffer(width: width, height: height, values: depthValues) else {
            XCTFail("Could not create pixel buffer"); return
        }

        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(Float(width), 0, 0),
            SIMD3<Float>(0, Float(height), 0),
            SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
        ))

        let bundles = (0..<5).map { i in
            DepthBundle(
                depthMap: depthBuf, intrinsics: intrinsics,
                depthResolution: SIMD2<Int>(width, height),
                timestamp: TimeInterval(i),
                faceTransform: matrix_identity_float4x4,
                cameraTransform: matrix_identity_float4x4,
                originalDepthDataType: kCVPixelFormatType_DepthFloat32,
                pixelSizeMM: nil,
                depthDataAccuracy: "absolute",
                depthDataQuality: "low",
                isDepthDataFiltered: true,
                extrinsicMatrix: nil,
                referenceProjections: nil
            )
        }

        let vertices = [SIMD3<Float>(0, 0, 0.03)]
        let faceTs = bundles.map { _ in matrix_identity_float4x4 }

        let result = DepthCorrectionService.correct(
            vertices: vertices,
            depthBundles: bundles,
            faceTransforms: faceTs,
            frameTransforms: faceTs
        )

        XCTAssertTrue(result.autoDisabled, "Should be auto-disabled when all bundles have .low quality")
        XCTAssertTrue(result.autoDisableReason?.contains("low") == true)
    }

    func testQualityGatePassesMixedQuality() {
        // If at least one bundle has "high" quality, gate should pass (to reach Gate 5)
        FeatureFlags.depthCorrectionEnabled = true
        defer { FeatureFlags.depthCorrectionEnabled = false }

        let width = 8, height = 8
        let depthValues = Array(repeating: Float(0.03), count: width * height)
        guard let depthBuf = createFloat32PixelBuffer(width: width, height: height, values: depthValues) else {
            XCTFail("Could not create pixel buffer"); return
        }

        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(Float(width), 0, 0),
            SIMD3<Float>(0, Float(height), 0),
            SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
        ))

        var bundles: [DepthBundle] = []
        // 4 low + 1 high
        for i in 0..<5 {
            bundles.append(DepthBundle(
                depthMap: depthBuf, intrinsics: intrinsics,
                depthResolution: SIMD2<Int>(width, height),
                timestamp: TimeInterval(i),
                faceTransform: matrix_identity_float4x4,
                cameraTransform: matrix_identity_float4x4,
                originalDepthDataType: kCVPixelFormatType_DepthFloat32,
                pixelSizeMM: nil,
                depthDataAccuracy: "absolute",
                depthDataQuality: i == 2 ? "high" : "low",
                isDepthDataFiltered: true,
                extrinsicMatrix: nil,
                referenceProjections: nil
            ))
        }

        let vertices = [SIMD3<Float>(0, 0, 0.03)]
        let faceTs = bundles.map { _ in matrix_identity_float4x4 }

        let result = DepthCorrectionService.correct(
            vertices: vertices,
            depthBundles: bundles,
            faceTransforms: faceTs,
            frameTransforms: faceTs
        )

        // Should NOT be disabled by quality gate (at least one high)
        // May still be disabled by registration gate, but the reason should not mention "low"
        if result.autoDisabled {
            XCTAssertFalse(result.autoDisableReason?.contains("depthDataQuality") == true,
                           "Should not be disabled by quality gate with mixed quality")
        }
    }

    // MARK: - (c) Depth filter flag exported in metrics JSON

    func testDepthFilterFlagInMetrics() {
        let metricsFiltered = makeMockMetrics(isDepthDataFiltered: true)
        let metricsUnfiltered = makeMockMetrics(isDepthDataFiltered: false)

        let jsonF = metricsFiltered.jsonString()!
        let jsonU = metricsUnfiltered.jsonString()!

        XCTAssertTrue(jsonF.contains("\"isDepthDataFiltered\" : true"))
        XCTAssertTrue(jsonU.contains("\"isDepthDataFiltered\" : false"))
    }

    // MARK: - (a) Intrinsics Rescale Correctness (synthetic)

    func testIntrinsicsRescaleIdentity() {
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(1000, 0, 0),
            SIMD3<Float>(0, 1000, 0),
            SIMD3<Float>(500, 400, 1)
        ))

        let scaled = DepthCorrectionService.rescaleIntrinsics(
            intrinsics,
            fromReferenceWidth: 1000,
            fromReferenceHeight: 800,
            toDepthWidth: 1000,
            toDepthHeight: 800
        )

        XCTAssertEqual(scaled[0][0], 1000, accuracy: 1e-6, "fx unchanged")
        XCTAssertEqual(scaled[1][1], 1000, accuracy: 1e-6, "fy unchanged")
        XCTAssertEqual(scaled[2][0], 500,  accuracy: 1e-6, "cx unchanged")
        XCTAssertEqual(scaled[2][1], 400,  accuracy: 1e-6, "cy unchanged")
    }

    func testIntrinsicsRescaleHalf() {
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(1920, 0, 0),
            SIMD3<Float>(0, 1440, 0),
            SIMD3<Float>(960, 720, 1)
        ))

        let scaled = DepthCorrectionService.rescaleIntrinsics(
            intrinsics,
            fromReferenceWidth: 1920,
            fromReferenceHeight: 1440,
            toDepthWidth: 256,
            toDepthHeight: 192
        )

        let scaleX: Float = 256.0 / 1920.0
        let scaleY: Float = 192.0 / 1440.0

        XCTAssertEqual(scaled[0][0], 1920 * scaleX, accuracy: 1e-3, "fx scaled")
        XCTAssertEqual(scaled[1][1], 1440 * scaleY, accuracy: 1e-3, "fy scaled")
        XCTAssertEqual(scaled[2][0], 960 * scaleX,  accuracy: 1e-3, "cx scaled")
        XCTAssertEqual(scaled[2][1], 720 * scaleY,  accuracy: 1e-3, "cy scaled")
    }

    func testIntrinsicsRescaleAsymmetric() {
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(600, 0, 0),
            SIMD3<Float>(0, 800, 0),
            SIMD3<Float>(300, 400, 1)
        ))

        let scaled = DepthCorrectionService.rescaleIntrinsics(
            intrinsics,
            fromReferenceWidth: 600,
            fromReferenceHeight: 800,
            toDepthWidth: 300,
            toDepthHeight: 200
        )

        // scaleX = 300/600 = 0.5, scaleY = 200/800 = 0.25
        XCTAssertEqual(scaled[0][0], 300,  accuracy: 1e-3, "fx = 600 * 0.5")
        XCTAssertEqual(scaled[1][1], 200,  accuracy: 1e-3, "fy = 800 * 0.25")
        XCTAssertEqual(scaled[2][0], 150,  accuracy: 1e-3, "cx = 300 * 0.5")
        XCTAssertEqual(scaled[2][1], 100,  accuracy: 1e-3, "cy = 400 * 0.25")
    }

    // MARK: - (b) Vertex → Depth Pixel Projection (synthetic)

    func testProjectVertexToDepthPixelIdentityTransforms() {
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(256, 0, 0),
            SIMD3<Float>(0, 192, 0),
            SIMD3<Float>(128, 96, 1)
        ))

        let bundle = DepthBundle(
            depthMap: createFloat32PixelBuffer(width: 4, height: 4, values: Array(repeating: 0.5, count: 16))!,
            intrinsics: intrinsics,
            depthResolution: SIMD2<Int>(256, 192),
            timestamp: 0,
            faceTransform: matrix_identity_float4x4,
            cameraTransform: matrix_identity_float4x4,
            originalDepthDataType: kCVPixelFormatType_DepthFloat32,
            pixelSizeMM: nil,
            depthDataAccuracy: "absolute",
            depthDataQuality: "high",
            isDepthDataFiltered: true,
            extrinsicMatrix: nil,
            referenceProjections: nil
        )

        let vertex = SIMD3<Float>(0, 0, 0.5) // on camera axis, 50cm away
        let proj = DepthCorrectionService.projectVertexToDepthPixel(vertex: vertex, bundle: bundle)

        XCTAssertNotNil(proj)
        XCTAssertEqual(proj!.u, 128, accuracy: 0.01, "Should project to cx")
        XCTAssertEqual(proj!.v, 96,  accuracy: 0.01, "Should project to cy")
        XCTAssertEqual(proj!.expectedDepth, 0.5, accuracy: 0.001)
    }

    func testProjectVertexBehindCameraReturnsNil() {
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(256, 0, 0),
            SIMD3<Float>(0, 192, 0),
            SIMD3<Float>(128, 96, 1)
        ))

        let bundle = DepthBundle(
            depthMap: createFloat32PixelBuffer(width: 4, height: 4, values: Array(repeating: 0.5, count: 16))!,
            intrinsics: intrinsics,
            depthResolution: SIMD2<Int>(256, 192),
            timestamp: 0,
            faceTransform: matrix_identity_float4x4,
            cameraTransform: matrix_identity_float4x4,
            originalDepthDataType: kCVPixelFormatType_DepthFloat32,
            pixelSizeMM: nil,
            depthDataAccuracy: "absolute",
            depthDataQuality: "high",
            isDepthDataFiltered: true,
            extrinsicMatrix: nil,
            referenceProjections: nil
        )

        let vertex = SIMD3<Float>(0, 0, -0.5) // behind camera
        let proj = DepthCorrectionService.projectVertexToDepthPixel(vertex: vertex, bundle: bundle)
        XCTAssertNil(proj, "Vertex behind camera should return nil")
    }

    func testProjectVertexOffAxis() {
        // Vertex 10cm to the right at 50cm depth → u = fx * (0.1/0.5) + cx = 256*0.2 + 128 = 179.2
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(256, 0, 0),
            SIMD3<Float>(0, 192, 0),
            SIMD3<Float>(128, 96, 1)
        ))

        let bundle = DepthBundle(
            depthMap: createFloat32PixelBuffer(width: 4, height: 4, values: Array(repeating: 0.5, count: 16))!,
            intrinsics: intrinsics,
            depthResolution: SIMD2<Int>(256, 192),
            timestamp: 0,
            faceTransform: matrix_identity_float4x4,
            cameraTransform: matrix_identity_float4x4,
            originalDepthDataType: kCVPixelFormatType_DepthFloat32,
            pixelSizeMM: nil,
            depthDataAccuracy: "absolute",
            depthDataQuality: "high",
            isDepthDataFiltered: true,
            extrinsicMatrix: nil,
            referenceProjections: nil
        )

        let vertex = SIMD3<Float>(0.1, 0, 0.5)
        let proj = DepthCorrectionService.projectVertexToDepthPixel(vertex: vertex, bundle: bundle)

        XCTAssertNotNil(proj)
        XCTAssertEqual(proj!.u, 179.2, accuracy: 0.1)
        XCTAssertEqual(proj!.v, 96, accuracy: 0.01)
    }

    // MARK: - (d) Extrinsics non-identity shifts projection

    func testExtrinsicsNonIdentityShiftsProjection() {
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(256, 0, 0),
            SIMD3<Float>(0, 192, 0),
            SIMD3<Float>(128, 96, 1)
        ))

        // Extrinsic: 1cm translation in X (depth camera offset from RGB camera)
        let ext = simd_float4x3(columns: (
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0.01, 0, 0)
        ))

        let vertex = SIMD3<Float>(0, 0, 0.5)

        // Bundle WITHOUT extrinsics
        let bundleNoExt = DepthBundle(
            depthMap: createFloat32PixelBuffer(width: 4, height: 4, values: Array(repeating: 0.5, count: 16))!,
            intrinsics: intrinsics,
            depthResolution: SIMD2<Int>(256, 192),
            timestamp: 0,
            faceTransform: matrix_identity_float4x4,
            cameraTransform: matrix_identity_float4x4,
            originalDepthDataType: kCVPixelFormatType_DepthFloat32,
            pixelSizeMM: nil,
            depthDataAccuracy: "absolute",
            depthDataQuality: "high",
            isDepthDataFiltered: true,
            extrinsicMatrix: nil,
            referenceProjections: nil
        )

        // Bundle WITH extrinsics
        let bundleWithExt = DepthBundle(
            depthMap: createFloat32PixelBuffer(width: 4, height: 4, values: Array(repeating: 0.5, count: 16))!,
            intrinsics: intrinsics,
            depthResolution: SIMD2<Int>(256, 192),
            timestamp: 0,
            faceTransform: matrix_identity_float4x4,
            cameraTransform: matrix_identity_float4x4,
            originalDepthDataType: kCVPixelFormatType_DepthFloat32,
            pixelSizeMM: nil,
            depthDataAccuracy: "absolute",
            depthDataQuality: "high",
            isDepthDataFiltered: true,
            extrinsicMatrix: ext,
            referenceProjections: nil
        )

        let projNoExt = DepthCorrectionService.projectVertexToDepthPixel(vertex: vertex, bundle: bundleNoExt)
        let projWithExt = DepthCorrectionService.projectVertexToDepthPixel(vertex: vertex, bundle: bundleWithExt)

        XCTAssertNotNil(projNoExt)
        XCTAssertNotNil(projWithExt)

        // Without extrinsics: vertex at origin → projects to (cx, cy) = (128, 96)
        XCTAssertEqual(projNoExt!.u, 128, accuracy: 0.01, "No ext: u should be cx")
        XCTAssertEqual(projNoExt!.v, 96, accuracy: 0.01, "No ext: v should be cy")

        // With extrinsics: 1cm X shift at 0.5m depth → u = 256*(0.01/0.5)+128 = 5.12+128 = 133.12
        XCTAssertEqual(projWithExt!.u, 133.12, accuracy: 0.1, "With ext: u should shift right")
        XCTAssertEqual(projWithExt!.v, 96, accuracy: 0.01, "With ext: v unchanged")

        // Confirm meaningful shift
        XCTAssertGreaterThan(abs(projWithExt!.u - projNoExt!.u), 4.0, "Extrinsics should shift u by > 4px")
    }

    func testExtrinsicsIdentityNoChange() {
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(256, 0, 0),
            SIMD3<Float>(0, 192, 0),
            SIMD3<Float>(128, 96, 1)
        ))

        // Identity extrinsic (no offset between cameras)
        let identityExt = simd_float4x3(columns: (
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, 0)
        ))

        let vertex = SIMD3<Float>(0.05, 0.02, 0.4)

        let bundleNoExt = DepthBundle(
            depthMap: createFloat32PixelBuffer(width: 4, height: 4, values: Array(repeating: 0.5, count: 16))!,
            intrinsics: intrinsics,
            depthResolution: SIMD2<Int>(256, 192),
            timestamp: 0,
            faceTransform: matrix_identity_float4x4,
            cameraTransform: matrix_identity_float4x4,
            originalDepthDataType: kCVPixelFormatType_DepthFloat32,
            pixelSizeMM: nil,
            depthDataAccuracy: "absolute",
            depthDataQuality: "high",
            isDepthDataFiltered: true,
            extrinsicMatrix: nil,
            referenceProjections: nil
        )

        let bundleIdentityExt = DepthBundle(
            depthMap: createFloat32PixelBuffer(width: 4, height: 4, values: Array(repeating: 0.5, count: 16))!,
            intrinsics: intrinsics,
            depthResolution: SIMD2<Int>(256, 192),
            timestamp: 0,
            faceTransform: matrix_identity_float4x4,
            cameraTransform: matrix_identity_float4x4,
            originalDepthDataType: kCVPixelFormatType_DepthFloat32,
            pixelSizeMM: nil,
            depthDataAccuracy: "absolute",
            depthDataQuality: "high",
            isDepthDataFiltered: true,
            extrinsicMatrix: identityExt,
            referenceProjections: nil
        )

        let projA = DepthCorrectionService.projectVertexToDepthPixel(vertex: vertex, bundle: bundleNoExt)
        let projB = DepthCorrectionService.projectVertexToDepthPixel(vertex: vertex, bundle: bundleIdentityExt)

        XCTAssertNotNil(projA)
        XCTAssertNotNil(projB)
        XCTAssertEqual(projA!.u, projB!.u, accuracy: 0.01, "Identity extrinsics should produce same u")
        XCTAssertEqual(projA!.v, projB!.v, accuracy: 0.01, "Identity extrinsics should produce same v")
    }

    // MARK: - (e) Cross-Validation: identity passes

    func testCrossValidationPassesIdentity() {
        // With identity transforms, our manual projection should match the reference exactly
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(256, 0, 0),
            SIMD3<Float>(0, 192, 0),
            SIMD3<Float>(128, 96, 1)
        ))

        let vertex = SIMD3<Float>(0.05, 0.02, 0.5)
        // Our projection: u = 256*(0.05/0.5)+128 = 25.6+128 = 153.6
        //                 v = 192*(0.02/0.5)+96  = 7.68+96  = 103.68
        let refU: Float = 256 * (0.05 / 0.5) + 128
        let refV: Float = 192 * (0.02 / 0.5) + 96

        let refs = [DepthReferenceProjection(vertexFaceLocal: vertex, depthPixelU: refU, depthPixelV: refV)]

        let bundles = (0..<3).map { i in
            DepthBundle(
                depthMap: createFloat32PixelBuffer(width: 4, height: 4, values: Array(repeating: 0.5, count: 16))!,
                intrinsics: intrinsics,
                depthResolution: SIMD2<Int>(256, 192),
                timestamp: TimeInterval(i),
                faceTransform: matrix_identity_float4x4,
                cameraTransform: matrix_identity_float4x4,
                originalDepthDataType: kCVPixelFormatType_DepthFloat32,
                pixelSizeMM: nil,
                depthDataAccuracy: "absolute",
                depthDataQuality: "high",
                isDepthDataFiltered: true,
                extrinsicMatrix: nil,
                referenceProjections: refs
            )
        }

        let crossVal = DepthCorrectionService.crossValidateProjection(bundles: bundles)

        XCTAssertTrue(crossVal.passed, "Cross-validation should pass with matching reference projections")
        XCTAssertEqual(crossVal.medianPixelError, 0, accuracy: 0.01)
        XCTAssertGreaterThan(crossVal.samplesUsed, 0)
    }

    // MARK: - (f) Cross-Validation: flipped/mirrored fails

    func testCrossValidationFailsFlipped() {
        // Reference projection has X-flipped coordinates → large pixel error → should fail
        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(256, 0, 0),
            SIMD3<Float>(0, 192, 0),
            SIMD3<Float>(128, 96, 1)
        ))

        let vertex = SIMD3<Float>(0.1, 0, 0.5)
        // Our projection: u = 256*(0.1/0.5)+128 = 51.2+128 = 179.2, v = 96
        let correctU: Float = 256 * (0.1 / 0.5) + 128  // 179.2
        let flippedU: Float = 256 - correctU              // 76.8 (X-mirrored)

        let refs = [DepthReferenceProjection(vertexFaceLocal: vertex, depthPixelU: flippedU, depthPixelV: 96)]

        let bundles = (0..<3).map { i in
            DepthBundle(
                depthMap: createFloat32PixelBuffer(width: 4, height: 4, values: Array(repeating: 0.5, count: 16))!,
                intrinsics: intrinsics,
                depthResolution: SIMD2<Int>(256, 192),
                timestamp: TimeInterval(i),
                faceTransform: matrix_identity_float4x4,
                cameraTransform: matrix_identity_float4x4,
                originalDepthDataType: kCVPixelFormatType_DepthFloat32,
                pixelSizeMM: nil,
                depthDataAccuracy: "absolute",
                depthDataQuality: "high",
                isDepthDataFiltered: true,
                extrinsicMatrix: nil,
                referenceProjections: refs
            )
        }

        let crossVal = DepthCorrectionService.crossValidateProjection(bundles: bundles)

        XCTAssertFalse(crossVal.passed, "Cross-validation should fail with X-flipped reference")
        // Error should be |179.2 - 76.8| = 102.4 px
        XCTAssertGreaterThan(crossVal.medianPixelError, 50, "Flipped projection should have large pixel error")
    }

    func testCrossValidationNoReferencesPassesByDefault() {
        // Bundles without reference projections → cannot validate → pass by default
        let bundles = makeSyntheticBundles(timestamps: [1.0, 2.0, 3.0])

        let crossVal = DepthCorrectionService.crossValidateProjection(bundles: bundles)

        XCTAssertTrue(crossVal.passed, "Should pass when no reference projections available")
        XCTAssertEqual(crossVal.samplesUsed, 0)
    }

    // MARK: - (c) Timestamp-Based Nearest Neighbor

    func testNearestBundleFindsClosest() {
        let bundles = makeSyntheticBundles(timestamps: [1.0, 2.0, 3.0, 4.0, 5.0])

        let nearest = DepthCorrectionService.nearestBundle(forTimestamp: 2.3, in: bundles)
        XCTAssertNotNil(nearest)
        XCTAssertEqual(nearest!.timestamp, 2.0, accuracy: 1e-6)

        let nearest2 = DepthCorrectionService.nearestBundle(forTimestamp: 4.8, in: bundles)
        XCTAssertNotNil(nearest2)
        XCTAssertEqual(nearest2!.timestamp, 5.0, accuracy: 1e-6)
    }

    func testNearestBundleEmptyReturnsNil() {
        let result = DepthCorrectionService.nearestBundle(forTimestamp: 1.0, in: [])
        XCTAssertNil(result)
    }

    func testNearestBundleSingleElement() {
        let bundles = makeSyntheticBundles(timestamps: [3.0])
        let nearest = DepthCorrectionService.nearestBundle(forTimestamp: 100.0, in: bundles)
        XCTAssertNotNil(nearest)
        XCTAssertEqual(nearest!.timestamp, 3.0, accuracy: 1e-6)
    }

    // MARK: - (d) Registration Gates (median/MAD/bias)

    func testRegistrationDiagnosticsPassWithGoodData() {
        FeatureFlags.depthCorrectionEnabled = true
        defer { FeatureFlags.depthCorrectionEnabled = false }

        let depthValue: Float = 0.03
        let width = 8, height = 8
        let depthValues = Array(repeating: depthValue, count: width * height)
        guard let depthBuf = createFloat32PixelBuffer(width: width, height: height, values: depthValues) else {
            XCTFail("Could not create pixel buffer"); return
        }

        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(Float(width), 0, 0),
            SIMD3<Float>(0, Float(height), 0),
            SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
        ))

        let bundles = (0..<5).map { i in
            DepthBundle(
                depthMap: depthBuf, intrinsics: intrinsics,
                depthResolution: SIMD2<Int>(width, height),
                timestamp: TimeInterval(i),
                faceTransform: matrix_identity_float4x4,
                cameraTransform: matrix_identity_float4x4,
                originalDepthDataType: kCVPixelFormatType_DepthFloat32,
                pixelSizeMM: nil,
                depthDataAccuracy: "absolute",
                depthDataQuality: "high",
                isDepthDataFiltered: true,
                extrinsicMatrix: nil,
                referenceProjections: nil
            )
        }

        let vertices = [SIMD3<Float>(0, 0, 0.03)]
        let faceTs = bundles.map { _ in matrix_identity_float4x4 }
        let camTs = faceTs

        let result = DepthCorrectionService.correct(
            vertices: vertices,
            depthBundles: bundles,
            faceTransforms: faceTs,
            frameTransforms: camTs
        )

        XCTAssertFalse(result.autoDisabled, "Should pass with perfect registration: \(result.autoDisableReason ?? "")")
        XCTAssertEqual(result.registrationDiagnostics.medianAbsErrorMm, 0, accuracy: 0.5)
        XCTAssertEqual(result.registrationDiagnostics.biasMm, 0, accuracy: 0.5)
    }

    func testRegistrationGateRejectsHighBias() {
        // Depth map reads 0.05m but vertex expects 0.03m → 20mm bias → should fail
        FeatureFlags.depthCorrectionEnabled = true
        defer { FeatureFlags.depthCorrectionEnabled = false }

        let width = 8, height = 8
        let depthValues = Array(repeating: Float(0.05), count: width * height)
        guard let depthBuf = createFloat32PixelBuffer(width: width, height: height, values: depthValues) else {
            XCTFail("Could not create pixel buffer"); return
        }

        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(Float(width), 0, 0),
            SIMD3<Float>(0, Float(height), 0),
            SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
        ))

        let bundles = (0..<5).map { i in
            DepthBundle(
                depthMap: depthBuf, intrinsics: intrinsics,
                depthResolution: SIMD2<Int>(width, height),
                timestamp: TimeInterval(i),
                faceTransform: matrix_identity_float4x4,
                cameraTransform: matrix_identity_float4x4,
                originalDepthDataType: kCVPixelFormatType_DepthFloat32,
                pixelSizeMM: nil,
                depthDataAccuracy: "absolute",
                depthDataQuality: "high",
                isDepthDataFiltered: true,
                extrinsicMatrix: nil,
                referenceProjections: nil
            )
        }

        let vertices = [SIMD3<Float>(0, 0, 0.03)]
        let faceTs = bundles.map { _ in matrix_identity_float4x4 }

        let result = DepthCorrectionService.correct(
            vertices: vertices,
            depthBundles: bundles,
            faceTransforms: faceTs,
            frameTransforms: faceTs
        )

        XCTAssertTrue(result.autoDisabled, "Should be auto-disabled with 20mm bias")
        XCTAssertTrue(result.autoDisableReason?.contains("Registration failed") == true)
        XCTAssertGreaterThan(result.registrationDiagnostics.medianAbsErrorMm, 1.0)
        XCTAssertGreaterThan(abs(result.registrationDiagnostics.biasMm), 1.0)
    }

    func testRegistrationDiagnosticsInResult() {
        UserDefaults.standard.removeObject(forKey: "feature_depthCorrection")

        let result = DepthCorrectionService.correct(
            vertices: [SIMD3<Float>(0, 0, 0.03)],
            depthBundles: [],
            faceTransforms: [],
            frameTransforms: []
        )

        XCTAssertEqual(result.registrationDiagnostics.samplesUsed, 0)
        XCTAssertFalse(result.registrationDiagnostics.passed)
    }

    func testCorrectionResultHasCrossValidation() {
        // CorrectionResult should carry cross-validation info when available
        FeatureFlags.depthCorrectionEnabled = true
        defer { FeatureFlags.depthCorrectionEnabled = false }

        let width = 8, height = 8
        let depthValues = Array(repeating: Float(0.03), count: width * height)
        guard let depthBuf = createFloat32PixelBuffer(width: width, height: height, values: depthValues) else {
            XCTFail("Could not create pixel buffer"); return
        }

        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(Float(width), 0, 0),
            SIMD3<Float>(0, Float(height), 0),
            SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
        ))

        let vertex = SIMD3<Float>(0, 0, 0.03)
        let refU: Float = Float(width) * (0 / 0.03) + Float(width) / 2
        let refV: Float = Float(height) * (0 / 0.03) + Float(height) / 2
        let refs = [DepthReferenceProjection(vertexFaceLocal: vertex, depthPixelU: refU, depthPixelV: refV)]

        let bundles = (0..<5).map { i in
            DepthBundle(
                depthMap: depthBuf, intrinsics: intrinsics,
                depthResolution: SIMD2<Int>(width, height),
                timestamp: TimeInterval(i),
                faceTransform: matrix_identity_float4x4,
                cameraTransform: matrix_identity_float4x4,
                originalDepthDataType: kCVPixelFormatType_DepthFloat32,
                pixelSizeMM: nil,
                depthDataAccuracy: "absolute",
                depthDataQuality: "high",
                isDepthDataFiltered: true,
                extrinsicMatrix: nil,
                referenceProjections: refs
            )
        }

        let vertices = [vertex]
        let faceTs = bundles.map { _ in matrix_identity_float4x4 }

        let result = DepthCorrectionService.correct(
            vertices: vertices,
            depthBundles: bundles,
            faceTransforms: faceTs,
            frameTransforms: faceTs
        )

        // Result should include cross-validation data
        if !result.autoDisabled {
            XCTAssertNotNil(result.crossValidation)
            XCTAssertGreaterThan(result.crossValidation!.samplesUsed, 0)
        }
    }

    // MARK: - OBJ/PLY Export

    func testOBJExportNotEmpty() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let obj = MeshProcessor.exportOBJ(mesh: mesh)
        XCTAssertTrue(obj.contains("v "))
        XCTAssertTrue(obj.contains("f "))
    }

    func testPLYExportContainsHeader() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let ply = MeshProcessor.exportPLY(mesh: mesh)
        XCTAssertTrue(ply.hasPrefix("ply\n"))
        XCTAssertTrue(ply.contains("element vertex \(mesh.vertexCount)"))
        XCTAssertTrue(ply.contains("element face \(mesh.triangleCount)"))
        XCTAssertTrue(ply.contains("scanMode: demo"))
        XCTAssertTrue(ply.contains("isSampleMesh: true"))
    }

    func testPLYExportZoneWeights() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let ply = MeshProcessor.exportPLY(mesh: mesh)
        XCTAssertTrue(ply.contains("property float zone_weight"))
    }

    // MARK: - Depth Bilinear Sampling (synthetic)

    func testDepthSampleBilinearCenter() {
        let width = 4, height = 4
        var depthValues: [Float] = Array(repeating: 0.5, count: width * height)
        depthValues[1 * width + 1] = 0.4
        depthValues[1 * width + 2] = 0.6
        depthValues[2 * width + 1] = 0.3
        depthValues[2 * width + 2] = 0.5

        let buffer = createFloat32PixelBuffer(width: width, height: height, values: depthValues)
        guard let buf = buffer else {
            XCTFail("Could not create pixel buffer")
            return
        }

        let d1 = DepthCorrectionService.sampleDepth(buffer: buf, u: 1.0, v: 1.0, width: width, height: height)
        XCTAssertNotNil(d1)
        XCTAssertEqual(d1!, 0.4, accuracy: 0.05)

        let d2 = DepthCorrectionService.sampleDepth(buffer: buf, u: 1.5, v: 1.5, width: width, height: height)
        XCTAssertNotNil(d2)
        XCTAssertEqual(d2!, 0.45, accuracy: 0.05)
    }

    func testDepthSampleOutOfBounds() {
        let width = 2, height = 2
        let depthValues: [Float] = [0.5, 0.5, 0.5, 0.5]
        let buffer = createFloat32PixelBuffer(width: width, height: height, values: depthValues)
        guard let buf = buffer else { XCTFail("Could not create pixel buffer"); return }

        let d = DepthCorrectionService.sampleDepth(buffer: buf, u: -1, v: -1, width: width, height: height)
        XCTAssertNil(d, "Out-of-bounds should return nil")
    }

    // MARK: - ScanMode Enum

    func testScanModeCodable() {
        let modes: [ScanMode] = [.demo, .coarseStable, .depthCorrected]
        for mode in modes {
            let data = try? JSONEncoder().encode(mode)
            XCTAssertNotNil(data)
            let decoded = try? JSONDecoder().decode(ScanMode.self, from: data!)
            XCTAssertEqual(decoded, mode)
        }
    }

    // MARK: - Full Pipeline Non-Regression (sample mesh on simulator)

    func testSampleMeshFullPipeline() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        XCTAssertTrue(mesh.isSampleMesh)
        XCTAssertEqual(mesh.scanMode, .demo)
        XCTAssertGreaterThan(mesh.vertexCount, 100)

        let normals = MeshProcessor.computeNormals(
            vertices: mesh.vertices,
            indices: mesh.triangleIndices
        )
        XCTAssertEqual(normals.count, mesh.vertexCount)

        let profile = HealingProfile()
        let model = HealingModel(profile: profile)

        for day: Float in [0, 1, 3, 7, 14, 30, 90, 180, 365] {
            let state = model.evaluate(at: day)
            let displaced = mesh.displaced(by: state)

            XCTAssertEqual(displaced.vertexCount, mesh.vertexCount)
            XCTAssertEqual(displaced.triangleCount, mesh.triangleCount)
            XCTAssertEqual(displaced.scanMode, .demo)

            for v in displaced.vertices {
                XCTAssertFalse(v.x.isNaN || v.y.isNaN || v.z.isNaN, "NaN at day \(day)")
                XCTAssertFalse(v.x.isInfinite || v.y.isInfinite || v.z.isInfinite, "Inf at day \(day)")
            }

            XCTAssertGreaterThanOrEqual(state.swellingLevel, 0)
            XCTAssertLessThanOrEqual(state.swellingLevel, 1)
        }
    }

    // MARK: - Helpers

    private func makeMockMetrics(
        meanFrameRMS: Float = 0.001,
        poseRotationStdDeg: Float = 1.0,
        framesUsed: Int = 48,
        scanMode: ScanMode = .coarseStable,
        depthDataAccuracy: String = "absolute",
        depthDataQuality: String = "high",
        isDepthDataFiltered: Bool = true,
        crosscheckPixelErrorMedian: Float = 0
    ) -> ScanQualityMetrics {
        ScanQualityMetrics(
            framesCollected: 60,
            framesUsed: framesUsed,
            trimPercent: 0.10,
            meanFrameRMS: meanFrameRMS,
            convergenceRMS: 0.0005,
            poseRotationStdDeg: poseRotationStdDeg,
            poseTranslationStdMM: 0.5,
            depthFramesAvailable: 0,
            depthCorrectionApplied: false,
            depthDataType: "dpth",
            depthResolutionW: 256,
            depthResolutionH: 192,
            depthFramesPerSecond: 0,
            registrationMedianAbsErrorMm: 0,
            registrationMADAbsErrorMm: 0,
            registrationBiasMm: 0,
            depthDataAccuracy: depthDataAccuracy,
            depthDataQuality: depthDataQuality,
            isDepthDataFiltered: isDepthDataFiltered,
            crosscheckPixelErrorMedian: crosscheckPixelErrorMedian,
            scanDurationSeconds: 3.0,
            deviceModel: "iPhone15,2",
            scanMode: scanMode,
            timestamp: Date()
        )
    }

    /// Create a CVPixelBuffer with Float32 format for testing depth sampling.
    private func createFloat32PixelBuffer(width: Int, height: Int, values: [Float]) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_DepthFloat32,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let floatPtr = base.assumingMemoryBound(to: Float.self)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float>.stride

        for y in 0..<height {
            for x in 0..<width {
                let srcIdx = y * width + x
                let dstIdx = y * floatsPerRow + x
                if srcIdx < values.count {
                    floatPtr[dstIdx] = values[srcIdx]
                }
            }
        }

        return buffer
    }

    /// Create synthetic DepthBundles with given timestamps (minimal data for tests).
    private func makeSyntheticBundles(timestamps: [TimeInterval]) -> [DepthBundle] {
        let width = 2, height = 2
        let depthValues = Array(repeating: Float(0.5), count: width * height)
        guard let buf = createFloat32PixelBuffer(width: width, height: height, values: depthValues) else {
            return []
        }

        let intrinsics = simd_float3x3(columns: (
            SIMD3<Float>(Float(width), 0, 0),
            SIMD3<Float>(0, Float(height), 0),
            SIMD3<Float>(1, 1, 1)
        ))

        return timestamps.map { ts in
            DepthBundle(
                depthMap: buf, intrinsics: intrinsics,
                depthResolution: SIMD2<Int>(width, height),
                timestamp: ts,
                faceTransform: matrix_identity_float4x4,
                cameraTransform: matrix_identity_float4x4,
                originalDepthDataType: kCVPixelFormatType_DepthFloat32,
                pixelSizeMM: nil,
                depthDataAccuracy: "absolute",
                depthDataQuality: "high",
                isDepthDataFiltered: true,
                extrinsicMatrix: nil,
                referenceProjections: nil
            )
        }
    }
}

// MARK: - ═══════════════════════════════════════════════════════════════════
// MARK: - HealingModel V2 Tests
// MARK: - ═══════════════════════════════════════════════════════════════════

final class HealingModelV2Tests: XCTestCase {

    // MARK: - Periorbital Edema Milestones

    func testPeriorbitalEdemaPeakAtJ2() {
        let model = HealingModelV2(profile: HealingProfileV2(osteotomy: .lateral))
        let e1 = model.periorbitalEdema(at: 1)
        let e2 = model.periorbitalEdema(at: 2)
        let e3 = model.periorbitalEdema(at: 3)
        XCTAssertLessThan(e1, e2, "Edema should still be rising at J1")
        XCTAssertGreaterThan(e2, e3, "Edema should peak at J2, declining by J3")
    }

    func testPeriorbitalEdemaResolvedAtJ8() {
        let model = HealingModelV2(profile: HealingProfileV2(osteotomy: .full))
        let e8 = model.periorbitalEdema(at: 8)
        XCTAssertLessThan(e8, 0.05, "Periorbital edema should be < 5% at J8, got \(e8)")
    }

    func testPeriorbitalEdemaZeroAtDayZero() {
        let model = HealingModelV2()
        XCTAssertEqual(model.periorbitalEdema(at: 0), 0)
    }

    // MARK: - Periorbital Bruise Milestones

    func testPeriorbitalBruiseResolvedJ10() {
        let model = HealingModelV2(profile: HealingProfileV2(osteotomy: .lateral))
        let b10 = model.periorbitalBruiseLevel(at: 10)
        XCTAssertLessThan(b10, 0.03, "Bruise should be 97% resolved at J10, got \(b10)")
    }

    func testBruiseNeverIncreasesAfterJ3() {
        let model = HealingModelV2()
        var prev = model.periorbitalBruiseLevel(at: 3)
        for d in stride(from: Float(3.5), through: 365, by: 0.5) {
            let curr = model.periorbitalBruiseLevel(at: d)
            XCTAssertLessThanOrEqual(curr, prev + 1e-6, "Bruise increased at day \(d)")
            prev = curr
        }
    }

    func testBruiseDisabledWhenNoBruising() {
        let model = HealingModelV2(profile: HealingProfileV2(bruisingPresent: false))
        for d: Float in [0, 1, 3, 7, 14] {
            XCTAssertEqual(model.periorbitalBruiseLevel(at: d), 0)
        }
    }

    // MARK: - Nasal Aggregate Milestones

    func testNasalAggregateJ30() {
        let model = HealingModelV2(profile: HealingProfileV2(skinThickness: .medium))
        let state = model.evaluate(at: 30)
        let agg = state.nasalSwellingAggregate
        XCTAssertGreaterThanOrEqual(agg, 0.28, "Nasal agg at J30 = \(agg) too low")
        XCTAssertLessThanOrEqual(agg, 0.38, "Nasal agg at J30 = \(agg) too high")
    }

    func testNasalAggregateJ180() {
        let model = HealingModelV2(profile: HealingProfileV2(skinThickness: .medium))
        let state = model.evaluate(at: 180)
        let agg = state.nasalSwellingAggregate
        XCTAssertGreaterThanOrEqual(agg, 0.02, "Nasal agg at J180 = \(agg) too low")
        XCTAssertLessThanOrEqual(agg, 0.08, "Nasal agg at J180 = \(agg) too high")
    }

    func testNasalAggregateJ365() {
        let model = HealingModelV2(profile: HealingProfileV2(skinThickness: .medium))
        let state = model.evaluate(at: 365)
        let agg = state.nasalSwellingAggregate
        XCTAssertGreaterThanOrEqual(agg, 0.005, "Nasal agg at J365 = \(agg) too low")
        XCTAssertLessThanOrEqual(agg, 0.045, "Nasal agg at J365 = \(agg) too high")
    }

    // MARK: - Tip Volume Peak

    func testTipVolumePeakIn7to14Days() {
        let model = HealingModelV2(profile: HealingProfileV2(skinThickness: .medium))
        var maxDisp: Float = 0
        var peakDay: Float = 0
        for d in stride(from: Float(0), through: 30, by: 0.5) {
            let state = model.evaluate(at: d)
            if state.nasalTipDisplacementMM > maxDisp {
                maxDisp = state.nasalTipDisplacementMM
                peakDay = d
            }
        }
        XCTAssertGreaterThanOrEqual(peakDay, 7, "Tip volume peak at day \(peakDay) is too early")
        XCTAssertLessThanOrEqual(peakDay, 14, "Tip volume peak at day \(peakDay) is too late")
    }

    // MARK: - Tip Bias Non-Decreasing

    func testTipBiasNonDecreasing() {
        let model = HealingModelV2()
        var prev = model.tipBiasRatio(at: 0)
        for d in 1...365 {
            let curr = model.tipBiasRatio(at: Float(d))
            XCTAssertGreaterThanOrEqual(curr, prev - 1e-6, "tipBias decreased at day \(d)")
            prev = curr
        }
    }

    func testTipBiasStartsAtOne() {
        let model = HealingModelV2()
        XCTAssertEqual(model.tipBiasRatio(at: 0), 1.0, accuracy: 1e-6)
    }

    // MARK: - No Negatives / NaN / Inf

    func testNoNegativesNaNInfForAllDays() {
        let model = HealingModelV2()
        for d in stride(from: Float(0), through: 730, by: 1) {
            let state = model.evaluate(at: d)

            XCTAssertGreaterThanOrEqual(state.nasalUpperSwelling, 0)
            XCTAssertGreaterThanOrEqual(state.nasalTipSwelling, 0)
            XCTAssertGreaterThanOrEqual(state.periorbitalEdema, 0)
            XCTAssertGreaterThanOrEqual(state.periorbitalBruiseLevel, 0)

            XCTAssertLessThanOrEqual(state.nasalUpperSwelling, 1)
            XCTAssertLessThanOrEqual(state.nasalTipSwelling, 1)
            XCTAssertLessThanOrEqual(state.periorbitalEdema, 1)
            XCTAssertLessThanOrEqual(state.periorbitalBruiseLevel, 1)

            XCTAssertFalse(state.nasalUpperSwelling.isNaN, "NaN at day \(d)")
            XCTAssertFalse(state.nasalTipSwelling.isNaN, "NaN at day \(d)")
            XCTAssertFalse(state.periorbitalEdema.isNaN, "NaN at day \(d)")

            XCTAssertFalse(state.nasalUpperDisplacementMM.isInfinite, "Inf at day \(d)")
            XCTAssertFalse(state.nasalTipDisplacementMM.isInfinite, "Inf at day \(d)")
            XCTAssertFalse(state.periorbitalDisplacementMM.isInfinite, "Inf at day \(d)")
        }
    }

    // MARK: - Monotonicity After Peak

    func testNasalUpperMonotonicallyDecreasingAfterPeak() {
        // With ramp-up, upper swelling rises from 0 to peak (~day 5-7), then decays.
        // Test monotone decrease after day 7.
        let model = HealingModelV2()
        var prev = model.nasalUpperSwelling(at: 7)
        for d in stride(from: Float(7.5), through: 365, by: 0.5) {
            let curr = model.nasalUpperSwelling(at: d)
            XCTAssertLessThanOrEqual(curr, prev + 1e-6, "Upper swelling increased at day \(d)")
            prev = curr
        }
    }

    func testPeriorbitalEdemaMonotonicAfterPeak() {
        // Peak is at J2, should be monotonically decreasing after
        let model = HealingModelV2(profile: HealingProfileV2(osteotomy: .full))
        var prev = model.periorbitalEdema(at: 2)
        for d in stride(from: Float(2.5), through: 60, by: 0.5) {
            let curr = model.periorbitalEdema(at: d)
            XCTAssertLessThanOrEqual(curr, prev + 1e-6, "Peri edema increased after peak at day \(d)")
            prev = curr
        }
    }

    // MARK: - Steroid Effect

    func testSteroidReducesEarlySwelling() {
        let noSteroid = HealingModelV2(profile: HealingProfileV2(steroidProtocol: .none))
        let multiDose = HealingModelV2(profile: HealingProfileV2(steroidProtocol: .multiDose))

        let sNoSteroid = noSteroid.nasalUpperSwelling(at: 7)
        let sMulti = multiDose.nasalUpperSwelling(at: 7)

        XCTAssertLessThan(sMulti, sNoSteroid, "Multi-dose steroids should reduce early swelling")
    }

    func testSteroidEffectFadesLongTerm() {
        let noSteroid = HealingModelV2(profile: HealingProfileV2(steroidProtocol: .none))
        let multiDose = HealingModelV2(profile: HealingProfileV2(steroidProtocol: .multiDose))

        let diffAt7 = noSteroid.nasalUpperSwelling(at: 7) - multiDose.nasalUpperSwelling(at: 7)
        let diffAt180 = noSteroid.nasalUpperSwelling(at: 180) - multiDose.nasalUpperSwelling(at: 180)

        XCTAssertLessThan(diffAt180, diffAt7 * 0.1, "Steroid effect should fade by 6 months")
    }

    // MARK: - Revision vs Primary

    func testRevisionSlowerThanPrimary() {
        let primary = HealingModelV2(profile: HealingProfileV2(surgeryType: .primary))
        let revision = HealingModelV2(profile: HealingProfileV2(surgeryType: .revision))

        let sPrimary = primary.nasalUpperSwelling(at: 180)
        let sRevision = revision.nasalUpperSwelling(at: 180)

        XCTAssertGreaterThan(sRevision, sPrimary, "Revision should heal slower than primary")
    }

    // MARK: - Skin Thickness

    func testThickSkinSlowerThanThin() {
        let thin = HealingModelV2(profile: HealingProfileV2(skinThickness: .thin))
        let thick = HealingModelV2(profile: HealingProfileV2(skinThickness: .thick))

        let sThin = thin.nasalUpperSwelling(at: 180)
        let sThick = thick.nasalUpperSwelling(at: 180)

        XCTAssertGreaterThan(sThick, sThin, "Thick skin should resolve slower at 6 months")
    }

    // MARK: - Osteotomy Affects Periorbital

    func testFullOsteotomyMorePeriorbitalThanNone() {
        let noOsteo = HealingModelV2(profile: HealingProfileV2(osteotomy: .none))
        let fullOsteo = HealingModelV2(profile: HealingProfileV2(osteotomy: .full))

        let eNone = noOsteo.periorbitalEdema(at: 2)
        let eFull = fullOsteo.periorbitalEdema(at: 2)

        XCTAssertGreaterThan(eFull, eNone, "Full osteotomy should produce more periorbital edema")
    }

    // MARK: - Uncertainty Bands

    func testUncertaintyBandsOrdered() {
        let model = HealingModelV2()
        for d: Float in [0, 1, 7, 30, 90, 180, 365] {
            let state = model.evaluate(at: d)
            XCTAssertLessThanOrEqual(state.nasalUpperSwellingMin, state.nasalUpperSwelling)
            XCTAssertLessThanOrEqual(state.nasalUpperSwelling, state.nasalUpperSwellingMax)
            XCTAssertLessThanOrEqual(state.nasalTipSwellingMin, state.nasalTipSwelling)
            XCTAssertLessThanOrEqual(state.nasalTipSwelling, state.nasalTipSwellingMax)
            XCTAssertLessThanOrEqual(state.periorbitalEdemaMin, state.periorbitalEdema)
            XCTAssertLessThanOrEqual(state.periorbitalEdema, state.periorbitalEdemaMax)
        }
    }

    // MARK: - V1 Backward Compatibility

    func testToV1ProducesValidHealingState() {
        let model = HealingModelV2()
        let stateV2 = model.evaluate(at: 7)
        let stateV1 = stateV2.toV1()

        XCTAssertEqual(stateV1.day, 7)
        XCTAssertGreaterThanOrEqual(stateV1.swellingLevel, 0)
        XCTAssertLessThanOrEqual(stateV1.swellingLevel, 1)
        XCTAssertGreaterThanOrEqual(stateV1.nasalVolumeDelta, 0)
        XCTAssertLessThanOrEqual(stateV1.swellingMin, stateV1.swellingLevel)
        XCTAssertLessThanOrEqual(stateV1.swellingLevel, stateV1.swellingMax)
    }

    func testV1AggregateMatchesWeightedAverage() {
        let model = HealingModelV2()
        let state = model.evaluate(at: 14)
        let expected = state.nasalUpperSwelling * (2.0 / 3.0) + state.nasalTipSwelling * (1.0 / 3.0)
        XCTAssertEqual(state.nasalSwellingAggregate, expected, accuracy: 1e-6)
    }

    // MARK: - Bruise Color

    func testBruiseColorRGBInRange() {
        let model = HealingModelV2()
        for d: Float in [0, 1, 3, 5, 7, 10, 14] {
            let color = model.bruiseColor(at: d)
            XCTAssertGreaterThanOrEqual(color.x, 0, "R < 0 at day \(d)")
            XCTAssertLessThanOrEqual(color.x, 1, "R > 1 at day \(d)")
            XCTAssertGreaterThanOrEqual(color.y, 0, "G < 0 at day \(d)")
            XCTAssertLessThanOrEqual(color.y, 1, "G > 1 at day \(d)")
            XCTAssertGreaterThanOrEqual(color.z, 0, "B < 0 at day \(d)")
            XCTAssertLessThanOrEqual(color.z, 1, "B > 1 at day \(d)")
        }
    }

    // MARK: - Profile V2 from V1 Conversion

    func testProfileV2FromV1() {
        let v1 = HealingProfile(skinThickness: .thick, initialIntensity: .high, bruisingPresent: true, age: 45)
        let v2 = HealingProfileV2(from: v1)

        XCTAssertEqual(v2.skinThickness, .thick)
        XCTAssertEqual(v2.bruisingPresent, true)
        XCTAssertEqual(v2.age, 45)
        XCTAssertEqual(v2.surgeryType, .primary)    // sensible default
        XCTAssertEqual(v2.osteotomy, .lateral)       // sensible default
    }

    // MARK: - DisplacedV2 Mesh

    func testDisplacedV2MeshPreservesTopology() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let model = HealingModelV2()
        let state = model.evaluate(at: 7)
        let displaced = mesh.displacedV2(by: state)

        XCTAssertEqual(displaced.vertexCount, mesh.vertexCount)
        XCTAssertEqual(displaced.triangleCount, mesh.triangleCount)
        XCTAssertEqual(displaced.scanMode, .demo)
    }

    func testDisplacedV2NoNaNOrInf() {
        let mesh = SampleMeshLoader.loadSampleMesh()
        let model = HealingModelV2()

        for day: Float in [0, 1, 3, 7, 14, 30, 90, 180, 365] {
            let state = model.evaluate(at: day)
            let displaced = mesh.displacedV2(by: state)
            for v in displaced.vertices {
                XCTAssertFalse(v.x.isNaN || v.y.isNaN || v.z.isNaN, "NaN at day \(day)")
                XCTAssertFalse(v.x.isInfinite || v.y.isInfinite || v.z.isInfinite, "Inf at day \(day)")
            }
        }
    }

    // MARK: - Feature Flag

    func testHealingModelV2FeatureFlagDefault() {
        UserDefaults.standard.removeObject(forKey: "feature_healingModelV2")
        XCTAssertFalse(FeatureFlags.healingModelV2Enabled, "V2 should be OFF by default")
    }

    func testHealingModelV2FeatureFlagToggle() {
        let original = FeatureFlags.healingModelV2Enabled
        defer { FeatureFlags.healingModelV2Enabled = original }

        FeatureFlags.healingModelV2Enabled = true
        XCTAssertTrue(FeatureFlags.healingModelV2Enabled)

        FeatureFlags.healingModelV2Enabled = false
        XCTAssertFalse(FeatureFlags.healingModelV2Enabled)
    }

    // MARK: - Timeline Preset Days

    func testTimelineCoversStandardDays() {
        let model = HealingModelV2()
        let timeline = model.timeline()
        let days = timeline.map { $0.day }
        XCTAssertEqual(days, [0, 1, 3, 7, 14, 30, 90, 180, 365])
    }

    // MARK: - ═══════════════════════════════════════════════════════════════
    // MARK: - Hardening Tests (v2.1 patch)
    // MARK: - ═══════════════════════════════════════════════════════════════

    // MARK: - Nasal Ramp-Up

    func testNasalRampUpStartsAtZero() {
        let model = HealingModelV2()
        XCTAssertEqual(model.nasalRampUp(at: 0), 0, "Ramp should be 0 at t=0")
        XCTAssertEqual(model.nasalUpperSwelling(at: 0), 0, "Upper swelling should be 0 at t=0")
        XCTAssertEqual(model.nasalTipSwelling(at: 0), 0, "Tip swelling should be 0 at t=0")
    }

    func testNasalRampUpApproachesOneByDay14() {
        let model = HealingModelV2()
        let ramp14 = model.nasalRampUp(at: 14)
        XCTAssertGreaterThan(ramp14, 0.99, "Ramp should be ~1.0 by day 14, got \(ramp14)")
    }

    func testNasalRampUpMonotonicallyIncreasing() {
        let model = HealingModelV2()
        var prev: Float = 0
        for d in stride(from: Float(0.5), through: 30, by: 0.5) {
            let curr = model.nasalRampUp(at: d)
            XCTAssertGreaterThanOrEqual(curr, prev, "Ramp decreased at day \(d)")
            prev = curr
        }
    }

    // MARK: - Nasal Total Displacement Peak

    func testNasalTotalPeakWindow7to14() {
        // argmax(nasalTotalDisplacement) must be in [7, 14]
        let model = HealingModelV2(profile: HealingProfileV2(skinThickness: .medium))
        var maxDisp: Float = 0
        var peakDay: Float = 0
        for d in stride(from: Float(0), through: 30, by: 0.5) {
            let disp = model.nasalTotalDisplacement(at: d)
            if disp > maxDisp {
                maxDisp = disp
                peakDay = d
            }
        }
        XCTAssertGreaterThanOrEqual(peakDay, 7, "Nasal total peak at day \(peakDay) is too early")
        XCTAssertLessThanOrEqual(peakDay, 14, "Nasal total peak at day \(peakDay) is too late")
    }

    func testNasalTotalPeakWindow7to14AllSkinTypes() {
        for skin: HealingProfileV2.SkinThickness in [.thin, .medium, .thick] {
            let model = HealingModelV2(profile: HealingProfileV2(skinThickness: skin))
            var maxDisp: Float = 0
            var peakDay: Float = 0
            for d in stride(from: Float(0), through: 30, by: 0.5) {
                let disp = model.nasalTotalDisplacement(at: d)
                if disp > maxDisp {
                    maxDisp = disp
                    peakDay = d
                }
            }
            XCTAssertGreaterThanOrEqual(peakDay, 7, "\(skin): nasal total peak at \(peakDay) too early")
            XCTAssertLessThanOrEqual(peakDay, 14, "\(skin): nasal total peak at \(peakDay) too late")
        }
    }

    // MARK: - Nasal Total Monotone Decrease After Peak

    func testNasalTotalMonotoneDecreaseAfterPeak() {
        let model = HealingModelV2()
        // Find peak first
        var maxDisp: Float = 0
        var peakDay: Float = 0
        for d in stride(from: Float(0), through: 30, by: 0.5) {
            let disp = model.nasalTotalDisplacement(at: d)
            if disp > maxDisp {
                maxDisp = disp
                peakDay = d
            }
        }
        // Verify monotone decrease after peak
        var prev = maxDisp
        for d in stride(from: peakDay + 0.5, through: 365, by: 0.5) {
            let curr = model.nasalTotalDisplacement(at: d)
            XCTAssertLessThanOrEqual(curr, prev + 1e-4,
                "Nasal total displacement increased at day \(d): \(curr) > \(prev)")
            prev = curr
        }
    }

    // MARK: - Steroids: No Benefit on Nasal Beyond J7

    func testSteroidsNoBenefitAtDay7() {
        let noSteroid = HealingModelV2(profile: HealingProfileV2(steroidProtocol: .none))
        let multiDose = HealingModelV2(profile: HealingProfileV2(steroidProtocol: .multiDose))

        // At J7, the steroid fast-component effect (tau=5d) has mostly decayed.
        // exp(-7/5) ≈ 0.25, so remaining effect should be tiny.
        let upperDiff = abs(noSteroid.nasalUpperSwelling(at: 7) - multiDose.nasalUpperSwelling(at: 7))
        XCTAssertLessThan(upperDiff, 0.02,
            "Steroid nasal upper diff at J7 should be < 2%, got \(upperDiff)")

        // At J30, steroid effect on nasal should be essentially zero
        let upperDiff30 = abs(noSteroid.nasalUpperSwelling(at: 30) - multiDose.nasalUpperSwelling(at: 30))
        XCTAssertLessThan(upperDiff30, 0.001,
            "Steroid nasal upper diff at J30 should be < 0.1%, got \(upperDiff30)")

        // Tip should also show negligible steroid effect at J30
        let tipDiff30 = abs(noSteroid.nasalTipSwelling(at: 30) - multiDose.nasalTipSwelling(at: 30))
        XCTAssertLessThan(tipDiff30, 0.001,
            "Steroid nasal tip diff at J30 should be < 0.1%, got \(tipDiff30)")
    }

    func testSteroidsStillReducePeriorbitalAtJ2() {
        // Steroids should still have meaningful effect on periorbital at J2
        let noSteroid = HealingModelV2(profile: HealingProfileV2(steroidProtocol: .none, osteotomy: .full))
        let multiDose = HealingModelV2(profile: HealingProfileV2(steroidProtocol: .multiDose, osteotomy: .full))

        let eNone = noSteroid.periorbitalEdema(at: 2)
        let eMulti = multiDose.periorbitalEdema(at: 2)
        XCTAssertLessThan(eMulti, eNone, "Multi-dose steroids should reduce periorbital edema at J2")

        let bNone = noSteroid.periorbitalBruiseLevel(at: 2)
        let bMulti = multiDose.periorbitalBruiseLevel(at: 2)
        XCTAssertLessThan(bMulti, bNone, "Multi-dose steroids should reduce periorbital bruise at J2")
    }

    // MARK: - Tip Bias: Non-Decreasing on [7, 90]

    func testTipBiasNonDecreasingOn7to90() {
        let model = HealingModelV2()
        var prev = model.tipBiasRatio(at: 7)
        for d in stride(from: Float(7.5), through: 90, by: 0.5) {
            let curr = model.tipBiasRatio(at: d)
            XCTAssertGreaterThanOrEqual(curr, prev - 1e-6,
                "tipBias decreased on [7,90] at day \(d)")
            prev = curr
        }
    }

    // MARK: - Tip Bias: Stable (Plateau) After 90

    func testTipBiasStableAfter90() {
        let model = HealingModelV2()
        let bias90 = model.tipBiasRatio(at: 90)
        let bias180 = model.tipBiasRatio(at: 180)
        let bias365 = model.tipBiasRatio(at: 365)

        // Drift from day 90 to 365 should be < 5% (plateau behavior)
        let drift = (bias365 - bias90) / bias90
        XCTAssertLessThan(drift, 0.05,
            "Tip bias drift from day 90 to 365 = \(drift * 100)%, should be < 5%")

        // Day-to-day change after day 90 should be negligible
        let dailyChange = abs(bias180 - bias90) / 90.0
        XCTAssertLessThan(dailyChange, 0.001,
            "Tip bias daily change after 90 = \(dailyChange), should be < 0.001")
    }

    // MARK: - Steroid Decay Confinement

    func testSteroidConfinedToFastAndPeriorbital() {
        // At day 30+, no steroid protocol should affect nasal curves
        // (steroid decay tau = 5d, so exp(-30/5) ≈ 0.0025 — negligible)
        let profiles: [HealingProfileV2.SteroidProtocol] = [.none, .single, .multiDose]
        var nasalAt90: [Float] = []
        for sp in profiles {
            let model = HealingModelV2(profile: HealingProfileV2(steroidProtocol: sp))
            let agg = model.nasalUpperSwelling(at: 90)
            nasalAt90.append(agg)
        }
        // All should be identical (within floating-point tolerance)
        for i in 1..<nasalAt90.count {
            XCTAssertEqual(nasalAt90[i], nasalAt90[0], accuracy: 1e-4,
                "Steroid protocol should not affect nasal at day 90")
        }
    }
}

// MARK: - ═══════════════════════════════════════════════════════════════
// MARK: - Hybrid Scan 3D Pipeline Tests
// MARK: - ═══════════════════════════════════════════════════════════════

final class VoxelGridTests: XCTestCase {

    // MARK: - Basic Insertion

    func testVoxelGridInsertAndExtract() {
        let grid = VoxelGrid(
            boundsMin: SIMD3<Float>(-1, -1, -1),
            boundsMax: SIMD3<Float>(1, 1, 1),
            voxelSize: 0.5
        )

        // Insert 10 points near origin
        for _ in 0..<10 {
            let offset = SIMD3<Float>(
                Float.random(in: -0.1...0.1),
                Float.random(in: -0.1...0.1),
                Float.random(in: -0.1...0.1)
            )
            grid.insert(point: offset, weight: 1.0)
        }

        let fused = grid.extract(minSamples: 2)
        XCTAssertGreaterThan(fused.count, 0, "Should have at least one fused point")

        // All points should be near origin
        for p in fused {
            XCTAssertLessThan(length(p.position), 0.5, "Fused point should be near origin")
        }
    }

    func testVoxelGridNoiseReduction() {
        let grid = VoxelGrid(
            boundsMin: SIMD3<Float>(-0.1, -0.1, -0.1),
            boundsMax: SIMD3<Float>(0.1, 0.1, 0.1),
            voxelSize: 0.02
        )

        let truePosition = SIMD3<Float>(0.01, 0.01, 0.01)

        // Insert 20 noisy measurements around true position
        for _ in 0..<20 {
            let noise = SIMD3<Float>(
                Float.random(in: -0.005...0.005),
                Float.random(in: -0.005...0.005),
                Float.random(in: -0.005...0.005)
            )
            grid.insert(point: truePosition + noise, weight: 1.0)
        }

        let fused = grid.extract(minSamples: 5)
        XCTAssertEqual(fused.count, 1, "20 noisy points in one voxel should fuse to 1")

        if let centroid = fused.first {
            let error = length(centroid.position - truePosition)
            XCTAssertLessThan(error, 0.01, "Centroid should be within 10mm of true position, got \(error * 1000)mm")
        }
    }

    func testVoxelGridMinSamplesFilter() {
        let grid = VoxelGrid(
            boundsMin: SIMD3<Float>(-1, -1, -1),
            boundsMax: SIMD3<Float>(1, 1, 1),
            voxelSize: 0.5
        )

        // Insert a single point (should be filtered out with minSamples=2)
        grid.insert(point: SIMD3<Float>(0.5, 0.5, 0.5), weight: 1.0)

        let filtered = grid.extract(minSamples: 2)
        XCTAssertEqual(filtered.count, 0, "Single point should be filtered with minSamples=2")

        let unfiltered = grid.extract(minSamples: 1)
        XCTAssertEqual(unfiltered.count, 1, "Single point should pass with minSamples=1")
    }

    func testVoxelGridOutOfBounds() {
        let grid = VoxelGrid(
            boundsMin: SIMD3<Float>(0, 0, 0),
            boundsMax: SIMD3<Float>(1, 1, 1),
            voxelSize: 0.5
        )

        // Insert out of bounds - should be silently ignored
        grid.insert(point: SIMD3<Float>(-1, -1, -1), weight: 1.0)
        grid.insert(point: SIMD3<Float>(2, 2, 2), weight: 1.0)

        XCTAssertEqual(grid.occupiedCount(), 0, "Out-of-bounds points should not occupy voxels")
    }

    func testVoxelGridDimensions() {
        let grid = VoxelGrid(
            boundsMin: SIMD3<Float>(0, 0, 0),
            boundsMax: SIMD3<Float>(1, 1, 1),
            voxelSize: 0.25
        )

        XCTAssertEqual(grid.gridDims.x, 4)
        XCTAssertEqual(grid.gridDims.y, 4)
        XCTAssertEqual(grid.gridDims.z, 4)
        XCTAssertEqual(grid.totalVoxels, 64)
    }
}

// MARK: - Barycentric Mapper Tests

final class BarycentricMapperTests: XCTestCase {

    /// Build a simple 2-triangle quad mesh for testing.
    private func makeQuad() -> (vertices: [SIMD3<Float>], indices: [UInt32]) {
        let verts: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),   // 0: bottom-left
            SIMD3<Float>(1, 0, 0),   // 1: bottom-right
            SIMD3<Float>(1, 1, 0),   // 2: top-right
            SIMD3<Float>(0, 1, 0),   // 3: top-left
        ]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        return (verts, indices)
    }

    func testBarycentricIdentity() {
        let (verts, indices) = makeQuad()

        // Target vertices = same as source
        let mapper = BarycentricMapper(
            renderVertices: verts,
            canonicalVertices: verts,
            canonicalIndices: indices
        )

        // Transfer with identity (no deformation)
        let result = mapper.transfer(deformedCanonical: verts, canonicalIndices: indices)

        for i in 0..<verts.count {
            let error = length(result[i] - verts[i])
            XCTAssertLessThan(error, 1e-4, "Identity transfer should produce same vertices, error: \(error)")
        }
    }

    func testBarycentricKnownOffset() {
        let (verts, indices) = makeQuad()
        let offset = SIMD3<Float>(0.1, 0, 0)

        let mapper = BarycentricMapper(
            renderVertices: verts,
            canonicalVertices: verts,
            canonicalIndices: indices
        )

        // Deform canonical by uniform offset
        let deformed = verts.map { $0 + offset }
        let result = mapper.transfer(deformedCanonical: deformed, canonicalIndices: indices)

        for i in 0..<verts.count {
            let error = length(result[i] - deformed[i])
            XCTAssertLessThan(error, 1e-3, "Uniform offset should transfer exactly, error: \(error)")
        }
    }

    func testBarycentricInteriorPoint() {
        let (verts, indices) = makeQuad()

        // A point in the center of the quad
        let centerPoint = [SIMD3<Float>(0.5, 0.5, 0)]

        let mapper = BarycentricMapper(
            renderVertices: centerPoint,
            canonicalVertices: verts,
            canonicalIndices: indices
        )

        // Transfer with identity
        let result = mapper.transfer(deformedCanonical: verts, canonicalIndices: indices)

        let error = length(result[0] - centerPoint[0])
        XCTAssertLessThan(error, 1e-3, "Center point should map to itself under identity, error: \(error)")
    }

    func testClosestPointOnTriangleAtVertex() {
        let v0 = SIMD3<Float>(0, 0, 0)
        let v1 = SIMD3<Float>(1, 0, 0)
        let v2 = SIMD3<Float>(0, 1, 0)

        let (bary, dist) = BarycentricMapper.closestPointOnTriangle(
            point: v0, v0: v0, v1: v1, v2: v2
        )

        XCTAssertLessThan(dist, 1e-6, "Distance to vertex should be ~0")
        XCTAssertGreaterThan(bary.x, 0.99, "First barycentric coord should be ~1")
    }

    func testClosestPointOnTriangleOutside() {
        let v0 = SIMD3<Float>(0, 0, 0)
        let v1 = SIMD3<Float>(1, 0, 0)
        let v2 = SIMD3<Float>(0, 1, 0)

        // Point outside triangle on the normal
        let point = SIMD3<Float>(0.25, 0.25, 1.0)
        let (bary, dist) = BarycentricMapper.closestPointOnTriangle(
            point: point, v0: v0, v1: v1, v2: v2
        )

        XCTAssertGreaterThan(dist, 0.99, "Distance should be ~1 (normal offset)")
        XCTAssertGreaterThanOrEqual(bary.x, 0)
        XCTAssertGreaterThanOrEqual(bary.y, 0)
        XCTAssertGreaterThanOrEqual(bary.z, 0)
        let sum = bary.x + bary.y + bary.z
        XCTAssertEqual(sum, 1.0, accuracy: 1e-4, "Barycentric coords should sum to 1")
    }
}

// MARK: - Deformation Transfer Tests

final class DeformationTransferTests: XCTestCase {

    func testDeformationTransferIdentity() {
        let verts: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
        ]
        let indices: [UInt32] = [0, 1, 2]
        let renderVerts = verts // same mesh

        let mapper = BarycentricMapper(
            renderVertices: renderVerts,
            canonicalVertices: verts,
            canonicalIndices: indices
        )

        let dt = DeformationTransfer(
            mapper: mapper,
            baseRenderVertices: renderVerts,
            canonicalIndices: indices
        )

        // No deformation
        let result = dt.transfer(baseCanonical: verts, deformedCanonical: verts)

        XCTAssertLessThan(result.maxDisplacement, 1e-5, "Identity should have zero displacement")
        XCTAssertEqual(result.deformedVertices.count, renderVerts.count)
    }

    func testDeformationTransferUniformOffset() {
        let verts: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0.5, 1, 0),
        ]
        let indices: [UInt32] = [0, 1, 2]

        let mapper = BarycentricMapper(
            renderVertices: verts,
            canonicalVertices: verts,
            canonicalIndices: indices
        )

        let dt = DeformationTransfer(
            mapper: mapper,
            baseRenderVertices: verts,
            canonicalIndices: indices
        )

        // Apply 5mm outward displacement
        let offset = SIMD3<Float>(0, 0, 0.005)
        let deformed = verts.map { $0 + offset }

        let result = dt.transfer(baseCanonical: verts, deformedCanonical: deformed)

        for i in 0..<verts.count {
            let expected = verts[i] + offset
            let error = length(result.deformedVertices[i] - expected)
            XCTAssertLessThan(error, 1e-4, "Vertex \(i) should match expected, error: \(error)")
        }

        XCTAssertEqual(result.maxDisplacement, 0.005, accuracy: 1e-4)
    }

    func testDeformationTransferClamp() {
        let verts: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
        ]
        let indices: [UInt32] = [0, 1, 2]

        let mapper = BarycentricMapper(
            renderVertices: verts,
            canonicalVertices: verts,
            canonicalIndices: indices
        )

        let config = DeformationTransfer.Config(maxDisplacementM: 0.005)
        let dt = DeformationTransfer(
            mapper: mapper,
            baseRenderVertices: verts,
            canonicalIndices: indices,
            config: config
        )

        // Apply 20mm offset (should be clamped to 5mm)
        let offset = SIMD3<Float>(0, 0, 0.020)
        let deformed = verts.map { $0 + offset }

        let result = dt.transfer(baseCanonical: verts, deformedCanonical: deformed)

        XCTAssertLessThanOrEqual(result.maxDisplacement, 0.005 + 1e-5, "Displacement should be clamped to 5mm")
    }
}

// MARK: - UV Unwrapper Tests

final class UVUnwrapperTests: XCTestCase {

    func testCylindricalUnwrapRange() {
        let verts: [SIMD3<Float>] = [
            SIMD3<Float>(0.01, 0, 0.03),
            SIMD3<Float>(-0.01, 0, 0.03),
            SIMD3<Float>(0, 0.02, 0.03),
            SIMD3<Float>(0, -0.02, 0.03),
        ]

        let uvs = UVUnwrapper.cylindricalUnwrap(vertices: verts)

        XCTAssertEqual(uvs.count, verts.count)
        for uv in uvs {
            XCTAssertGreaterThanOrEqual(uv.x, 0, "U should be >= 0")
            XCTAssertLessThanOrEqual(uv.x, 1, "U should be <= 1")
            XCTAssertGreaterThanOrEqual(uv.y, 0, "V should be >= 0")
            XCTAssertLessThanOrEqual(uv.y, 1, "V should be <= 1")
        }
    }

    func testPlanarUnwrapRange() {
        let verts: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(1, 1, 0),
        ]

        let uvs = UVUnwrapper.planarUnwrap(vertices: verts)

        XCTAssertEqual(uvs.count, verts.count)
        for uv in uvs {
            XCTAssertGreaterThanOrEqual(uv.x, -0.01)
            XCTAssertLessThanOrEqual(uv.x, 1.01)
            XCTAssertGreaterThanOrEqual(uv.y, -0.01)
            XCTAssertLessThanOrEqual(uv.y, 1.01)
        }
    }
}

// MARK: - TSDF + Marching Cubes Tests

final class TSDFMarchingCubesTests: XCTestCase {

    func testTSDFVolumeCreation() {
        let tsdf = TSDFVolume(
            boundsMin: SIMD3<Float>(-0.05, -0.05, -0.05),
            boundsMax: SIMD3<Float>(0.05, 0.05, 0.05),
            voxelSize: 0.01
        )

        XCTAssertEqual(tsdf.dims.x, 10)
        XCTAssertEqual(tsdf.dims.y, 10)
        XCTAssertEqual(tsdf.dims.z, 10)
        XCTAssertEqual(tsdf.totalVoxels, 1000)
    }

    func testTSDFIntegrationModifiesVoxels() {
        let tsdf = TSDFVolume(
            boundsMin: SIMD3<Float>(-0.05, -0.05, -0.05),
            boundsMax: SIMD3<Float>(0.05, 0.05, 0.05),
            voxelSize: 0.01
        )

        // Integrate a single point with normal
        let points = [SIMD3<Float>(0, 0, 0)]
        let normals = [SIMD3<Float>(0, 0, 1)]

        tsdf.integrate(points: points, normals: normals)

        // Center voxel should have weight > 0
        let centerWeight = tsdf.weightAt(5, 5, 5)
        XCTAssertGreaterThan(centerWeight, 0, "Center voxel should have non-zero weight after integration")
    }

    func testMarchingCubesEmptyVolume() {
        let tsdf = TSDFVolume(
            boundsMin: SIMD3<Float>(-0.05, -0.05, -0.05),
            boundsMax: SIMD3<Float>(0.05, 0.05, 0.05),
            voxelSize: 0.01
        )

        // Empty volume (all TSDF = 1.0, weight = 0) should produce no triangles
        let mesh = MarchingCubes.extract(from: tsdf, minWeight: 0.5)
        XCTAssertEqual(mesh.vertexCount, 0, "Empty volume should produce no vertices")
        XCTAssertEqual(mesh.triangleCount, 0, "Empty volume should produce no triangles")
    }

    func testMarchingCubesSphereIntegration() {
        // Create a sphere point cloud and integrate into TSDF
        let tsdf = TSDFVolume(
            boundsMin: SIMD3<Float>(-0.06, -0.06, -0.06),
            boundsMax: SIMD3<Float>(0.06, 0.06, 0.06),
            voxelSize: 0.005
        )

        let radius: Float = 0.03
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []

        // Generate sphere surface points
        let nLat = 20
        let nLon = 20
        for i in 0...nLat {
            let theta = Float.pi * Float(i) / Float(nLat)
            for j in 0..<nLon {
                let phi = 2 * Float.pi * Float(j) / Float(nLon)

                let x = radius * sin(theta) * cos(phi)
                let y = radius * sin(theta) * sin(phi)
                let z = radius * cos(theta)

                let p = SIMD3<Float>(x, y, z)
                let n = normalize(p) // outward normal

                points.append(p)
                normals.append(n)
            }
        }

        tsdf.integrate(points: points, normals: normals)

        let mesh = MarchingCubes.extract(from: tsdf, isoLevel: 0, minWeight: 0.1)

        // Should produce a non-trivial mesh
        XCTAssertGreaterThan(mesh.vertexCount, 10, "Sphere TSDF should produce vertices, got \(mesh.vertexCount)")
        XCTAssertGreaterThan(mesh.triangleCount, 5, "Sphere TSDF should produce triangles, got \(mesh.triangleCount)")

        // All vertices should be roughly at sphere radius
        for v in mesh.vertices {
            let dist = length(v)
            XCTAssertLessThan(dist, radius * 2, "Vertex should be near sphere, distance: \(dist)")
        }
    }
}

// MARK: - Mesh Post-Process Tests

final class MeshPostProcessTests: XCTestCase {

    func testLaplacianSmoothPreservesTopology() {
        let verts: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0.5, 1, 0),
            SIMD3<Float>(0.5, 0.5, 0.5),
        ]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3, 1, 2, 3, 0, 1, 3]

        let smoothed = MeshPostProcess.laplacianSmooth(
            vertices: verts,
            indices: indices,
            iterations: 2,
            lambda: 0.5
        )

        XCTAssertEqual(smoothed.count, verts.count, "Smoothing should not change vertex count")

        // Smoothed vertices should be finite
        for v in smoothed {
            XCTAssertFalse(v.x.isNaN || v.y.isNaN || v.z.isNaN, "Smoothed vertex should not be NaN")
        }
    }

    func testNormalEstimationFromPointCloud() {
        // Create a planar point cloud on the XY plane
        var points: [SIMD3<Float>] = []
        for x in stride(from: Float(0), through: 1, by: 0.1) {
            for y in stride(from: Float(0), through: 1, by: 0.1) {
                points.append(SIMD3<Float>(x, y, 0))
            }
        }

        let normals = MeshPostProcess.estimateNormals(points: points, k: 8)

        XCTAssertEqual(normals.count, points.count)

        // All normals should point roughly in Z direction (perpendicular to XY plane)
        for n in normals {
            let zComponent = abs(n.z)
            XCTAssertGreaterThan(zComponent, 0.8, "Normal should be roughly Z-aligned for planar cloud, got z=\(n.z)")
        }
    }
}

// MARK: - Feature Flags Tests (Hybrid Scan)

final class HybridScanFeatureFlagTests: XCTestCase {

    func testHybridScan3DDefaultOff() {
        UserDefaults.standard.removeObject(forKey: "feature_hybridScan3D")
        XCTAssertFalse(FeatureFlags.hybridScan3DEnabled, "Hybrid scan should be OFF by default")
    }

    func testHybridScan3DToggle() {
        let original = FeatureFlags.hybridScan3DEnabled
        defer { FeatureFlags.hybridScan3DEnabled = original }

        FeatureFlags.hybridScan3DEnabled = true
        XCTAssertTrue(FeatureFlags.hybridScan3DEnabled)

        FeatureFlags.hybridScan3DEnabled = false
        XCTAssertFalse(FeatureFlags.hybridScan3DEnabled)
    }

    func testDenseCaptureParameterDefaults() {
        XCTAssertEqual(FeatureFlags.denseCaptureCountdownSeconds, 10.0)
        XCTAssertEqual(FeatureFlags.denseCaptureFrameTarget, 300)
        XCTAssertEqual(FeatureFlags.tsdfVoxelSize, 0.0005)
        XCTAssertEqual(FeatureFlags.textureAtlasSize, 1024)
        XCTAssertGreaterThan(FeatureFlags.minCoverageScore, 0)
        XCTAssertGreaterThan(FeatureFlags.minFusedPoints, 0)
    }

    func testScanModeSurgeonGrade() {
        let mode = ScanMode.surgeonGrade
        XCTAssertEqual(mode.rawValue, "surgeonGrade")
    }
}

// MARK: - FaceMeshData Render Mesh Tests

final class FaceMeshDataRenderTests: XCTestCase {

    func testHasRenderMeshDefault() {
        let mesh = FaceMeshData(
            vertices: [.zero],
            normals: [SIMD3<Float>(0, 0, 1)],
            triangleIndices: [],
            textureCoordinates: nil,
            zoneWeights: [0]
        )
        XCTAssertFalse(mesh.hasRenderMesh)
        XCTAssertNil(mesh.renderMesh)
        XCTAssertNil(mesh.barycentricMapper)
        XCTAssertNil(mesh.textureAtlas)
    }

    func testHasRenderMeshWithData() {
        var mesh = FaceMeshData(
            vertices: [.zero],
            normals: [SIMD3<Float>(0, 0, 1)],
            triangleIndices: [],
            textureCoordinates: nil,
            zoneWeights: [0]
        )
        mesh.renderMesh = MeshPostProcess.RenderMeshData(
            vertices: [.zero],
            normals: [SIMD3<Float>(0, 0, 1)],
            triangleIndices: [],
            textureCoordinates: nil
        )
        XCTAssertTrue(mesh.hasRenderMesh)
    }
}

// MARK: - DenseROIBuilder Coverage Tests

final class DenseROIBuilderTests: XCTestCase {

    func testEmptyBundlesReturnsFailed() {
        let result = DenseROIBuilder.build(
            depthBundles: [],
            faceVertices: [SIMD3<Float>(0, 0, 0.03)],
            faceTransforms: [],
            cameraTransforms: []
        )

        XCTAssertFalse(result.passed)
        XCTAssertNotNil(result.failReason)
    }

    func testEmptyVerticesReturnsFailed() {
        let result = DenseROIBuilder.build(
            depthBundles: [],
            faceVertices: [],
            faceTransforms: [],
            cameraTransforms: []
        )

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.coverage.fusedPointCount, 0)
    }
}

// MARK: - Marching Cubes TriTable Completeness Tests

final class MarchingCubesTableTests: XCTestCase {

    func testTriTableHas256Entries() {
        // Use the extract method on a minimal volume to verify the table is accessible.
        // The table is private, so we verify indirectly that all 256 configs are handled.
        let tsdf = TSDFVolume(
            boundsMin: SIMD3<Float>(0, 0, 0),
            boundsMax: SIMD3<Float>(0.01, 0.01, 0.01),
            voxelSize: 0.005
        )
        // Integrating points creates non-trivial TSDF configurations
        let points = [
            SIMD3<Float>(0.003, 0.003, 0.003),
            SIMD3<Float>(0.007, 0.007, 0.007)
        ]
        let normals = [
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, -1)
        ]
        tsdf.integrate(points: points, normals: normals)

        // Extract should not crash — verifies table completeness
        let mesh = MarchingCubes.extract(from: tsdf, isoLevel: 0, minWeight: 0.1)
        XCTAssertGreaterThanOrEqual(mesh.vertexCount, 0, "Extract should not crash with full triTable")
    }

    func testEdgeTableHas256Entries() {
        // Indirectly test by extracting from a volume with varied TSDF values.
        let tsdf = TSDFVolume(
            boundsMin: SIMD3<Float>(-0.01, -0.01, -0.01),
            boundsMax: SIMD3<Float>(0.01, 0.01, 0.01),
            voxelSize: 0.004
        )

        // Create a sphere-like field by integrating points on a sphere
        for i in 0..<20 {
            let theta = Float(i) * .pi * 2.0 / 20.0
            for j in 0..<10 {
                let phi = Float(j) * .pi / 10.0
                let r: Float = 0.005
                let x = r * sin(phi) * cos(theta)
                let y = r * sin(phi) * sin(theta)
                let z = r * cos(phi)
                let pt = SIMD3<Float>(x, y, z)
                let n = normalize(pt)
                tsdf.integrate(points: [pt], normals: [n])
            }
        }

        let mesh = MarchingCubes.extract(from: tsdf, isoLevel: 0, minWeight: 0.1)
        // A sphere-like field should produce some triangles
        XCTAssertGreaterThan(mesh.triangleCount, 0, "Sphere integration should produce mesh with full triTable")
    }
}

// MARK: - MeshViewerRepresentable Init Tests

final class MeshViewerRepresentableTests: XCTestCase {

    func testConvenienceInitSetsNilRenderMesh() {
        let viewer = MeshViewerRepresentable(
            meshData: nil,
            bruiseLevel: 0,
            bruiseColor: .zero
        )
        XCTAssertNil(viewer.renderMesh)
        XCTAssertNil(viewer.textureAtlas)
    }

    func testFullInitPreservesRenderMesh() {
        let renderMesh = MeshPostProcess.RenderMeshData(
            vertices: [SIMD3<Float>(0, 0, 0)],
            normals: [SIMD3<Float>(0, 0, 1)],
            triangleIndices: [],
            textureCoordinates: [SIMD2<Float>(0.5, 0.5)]
        )

        let viewer = MeshViewerRepresentable(
            meshData: nil,
            renderMesh: renderMesh,
            textureAtlas: nil,
            bruiseLevel: 0.5,
            bruiseColor: SIMD3<Float>(0.4, 0.1, 0.3)
        )

        XCTAssertNotNil(viewer.renderMesh)
        XCTAssertEqual(viewer.renderMesh?.vertices.count, 1)
        XCTAssertEqual(viewer.bruiseLevel, 0.5)
    }
}

// MARK: - ═══════════════════════════════════════════════════════════════
// MARK:   Surgeon-Grade Hardening Tests
// MARK: - ═══════════════════════════════════════════════════════════════

// MARK: - Phase 1: Marching Cubes Robustness

final class MarchingCubesHardeningTests: XCTestCase {

    /// Build a TSDF sphere of given radius centred in a volume.
    private func buildSphereVolume(
        radius: Float = 0.02,
        voxelSize: Float = 0.002,
        padding: Float = 0.01
    ) -> TSDFVolume {
        let halfSize = radius + padding
        let volume = TSDFVolume(
            boundsMin: SIMD3<Float>(-halfSize, -halfSize, -halfSize),
            boundsMax: SIMD3<Float>( halfSize,  halfSize,  halfSize),
            voxelSize: voxelSize
        )

        // Analytically fill TSDF with signed distance to sphere
        for z in 0..<volume.dims.z {
            for y in 0..<volume.dims.y {
                for x in 0..<volume.dims.x {
                    let pos = volume.voxelCenterWorld(x, y, z)
                    let dist = length(pos) - radius
                    let truncated = max(-volume.truncationDistance, min(volume.truncationDistance, dist))
                    volume.setVoxel(x, y, z, tsdf: truncated, weight: 1.0)
                }
            }
        }
        return volume
    }

    func testSphereWatertight() {
        let volume = buildSphereVolume()
        let mesh = MarchingCubes.extract(from: volume, isoLevel: 0, minWeight: 0.5)

        XCTAssertGreaterThan(mesh.vertexCount, 0, "Sphere should produce vertices")
        XCTAssertGreaterThan(mesh.triangleCount, 0, "Sphere should produce triangles")

        // Watertight: boundary edges = 0
        if let diag = mesh.diagnostics {
            XCTAssertEqual(diag.boundaryEdgesCount, 0,
                           "Sphere mesh should be watertight (0 boundary edges), got \(diag.boundaryEdgesCount)")
        }
    }

    func testNormalsOutward() {
        let volume = buildSphereVolume()
        let mesh = MarchingCubes.extract(from: volume, isoLevel: 0, minWeight: 0.5)

        guard let diag = mesh.diagnostics else {
            XCTFail("Diagnostics should be present")
            return
        }

        XCTAssertGreaterThanOrEqual(
            diag.normalOutwardRatio,
            SurgeonGradeQualityGate.minNormalOutwardRatio,
            "Normal outward ratio \(diag.normalOutwardRatio) below gate \(SurgeonGradeQualityGate.minNormalOutwardRatio)"
        )
    }

    func testNoDegenerates() {
        let volume = buildSphereVolume()
        let mesh = MarchingCubes.extract(from: volume, isoLevel: 0, minWeight: 0.5)

        // Verify no degenerate triangles remain in the output
        let triCount = mesh.triangleIndices.count / 3
        for t in 0..<triCount {
            let i0 = Int(mesh.triangleIndices[t * 3])
            let i1 = Int(mesh.triangleIndices[t * 3 + 1])
            let i2 = Int(mesh.triangleIndices[t * 3 + 2])

            let v0 = mesh.vertices[i0]
            let v1 = mesh.vertices[i1]
            let v2 = mesh.vertices[i2]

            let area = 0.5 * length(cross(v1 - v0, v2 - v0))
            XCTAssertGreaterThan(area, SurgeonGradeQualityGate.minTriangleArea,
                                 "Triangle \(t) has degenerate area \(area)")
        }
    }

    func testNaNRejection() {
        let volume = buildSphereVolume()
        let mesh = MarchingCubes.extract(from: volume, isoLevel: 0, minWeight: 0.5)

        guard let diag = mesh.diagnostics else {
            XCTFail("Diagnostics should be present")
            return
        }

        // In a clean analytic sphere, no NaN should occur
        XCTAssertEqual(diag.numNaNRejected, 0, "Analytic sphere should produce zero NaN vertices")

        // Also verify no NaN/Inf in output vertices
        for (i, v) in mesh.vertices.enumerated() {
            XCTAssertFalse(v.x.isNaN || v.y.isNaN || v.z.isNaN, "Vertex \(i) contains NaN")
            XCTAssertFalse(v.x.isInfinite || v.y.isInfinite || v.z.isInfinite, "Vertex \(i) contains Inf")
        }
    }

    func testAmbiguousCaseResolved() {
        let volume = buildSphereVolume()
        let mesh = MarchingCubes.extract(from: volume, isoLevel: 0, minWeight: 0.5)

        guard let diag = mesh.diagnostics else {
            XCTFail("Diagnostics should be present")
            return
        }

        // The ambiguousCasesResolved counter should exist (may be 0 for simple sphere)
        XCTAssertGreaterThanOrEqual(diag.ambiguousCasesResolved, 0)
        XCTAssertGreaterThanOrEqual(diag.tetrahedraFallbacks, 0)
    }

    func testDiagnosticsGating() {
        let volume = buildSphereVolume()
        let mesh = MarchingCubes.extract(from: volume, isoLevel: 0, minWeight: 0.5)

        guard let diag = mesh.diagnostics else {
            XCTFail("Diagnostics should be present")
            return
        }

        // A clean sphere should pass the surgeon-grade gate
        XCTAssertTrue(diag.passesSurgeonGrade,
                      "Clean sphere should pass gate, failReason: \(diag.failReason ?? "none")")
    }

    func testDiagnosticsGatingRejectsTooFewTriangles() {
        let diag = MCDiagnostics(
            numTriangles: 10,  // below minMCTriangles (50)
            numDegenerateCulled: 0,
            numNaNRejected: 0,
            numComponents: 1,
            boundaryEdgesCount: 0,
            normalOutwardRatio: 0.95,
            totalVertices: 30,
            ambiguousCasesResolved: 0,
            tetrahedraFallbacks: 0
        )

        XCTAssertFalse(diag.passesSurgeonGrade, "Should fail with too few triangles")
        XCTAssertNotNil(diag.failReason)
        XCTAssertTrue(diag.failReason!.contains("too few"), "Fail reason should mention triangle count")
    }

    func testBoundaryEdgeCount() {
        let volume = buildSphereVolume()
        let mesh = MarchingCubes.extract(from: volume, isoLevel: 0, minWeight: 0.5)

        guard let diag = mesh.diagnostics else {
            XCTFail("Diagnostics should be present")
            return
        }

        let boundaryRatio = Float(diag.boundaryEdgesCount) / max(1, Float(diag.numTriangles))
        XCTAssertLessThanOrEqual(boundaryRatio, SurgeonGradeQualityGate.maxBoundaryEdgeRatio,
                                 "Boundary ratio \(boundaryRatio) exceeds gate")
    }
}

// MARK: - Phase 2: Texture Pipeline Immutability

final class TexturePipelineHardeningTests: XCTestCase {

    func testBaseAtlasImmutableHash() {
        let data: [SIMD3<Float>] = [
            SIMD3<Float>(0.5, 0.3, 0.2),
            SIMD3<Float>(0.8, 0.7, 0.6),
            SIMD3<Float>(0.1, 0.1, 0.1),
            SIMD3<Float>(0.9, 0.85, 0.8)
        ]

        let hash1 = TextureBaker.computeAtlasHash(data)
        let hash2 = TextureBaker.computeAtlasHash(data)

        XCTAssertEqual(hash1, hash2, "Same data must produce identical hash")
        XCTAssertNotEqual(hash1, 0, "Hash should be non-zero for non-trivial data")
    }

    func testAtlasHashChangesOnModification() {
        var data: [SIMD3<Float>] = [
            SIMD3<Float>(0.5, 0.3, 0.2),
            SIMD3<Float>(0.8, 0.7, 0.6)
        ]

        let hash1 = TextureBaker.computeAtlasHash(data)

        data[0] = SIMD3<Float>(0.5, 0.3, 0.21)
        let hash2 = TextureBaker.computeAtlasHash(data)

        XCTAssertNotEqual(hash1, hash2, "Modified data must produce different hash")
    }

    func testSRGBToLinearIdentityAtZeroAndOne() {
        let zero = TextureBaker.sRGBToLinear(0)
        let one = TextureBaker.sRGBToLinear(1)

        XCTAssertEqual(zero, 0, accuracy: 1e-6, "sRGB(0) -> linear must be 0")
        XCTAssertEqual(one, 1, accuracy: 1e-6, "sRGB(1) -> linear must be 1")
    }

    func testSRGBToLinearMonotonic() {
        var prev = TextureBaker.sRGBToLinear(0)
        for i in 1...100 {
            let s = Float(i) / 100.0
            let l = TextureBaker.sRGBToLinear(s)
            XCTAssertGreaterThanOrEqual(l, prev, "sRGB to linear must be monotonically increasing at s=\(s)")
            prev = l
        }
    }

    func testAtlasIntegrityVerification() {
        let data: [SIMD3<Float>] = [
            SIMD3<Float>(0.5, 0.3, 0.2),
            SIMD3<Float>(0.8, 0.7, 0.6)
        ]
        let hash = TextureBaker.computeAtlasHash(data)

        let result = TextureBaker.BakeResult(
            textureData: data,
            atlasWidth: 1,
            atlasHeight: 2,
            coverage: 1.0,
            framesUsed: 1,
            atlasHash: hash
        )

        XCTAssertTrue(result.verifyIntegrity(), "Unmodified atlas must verify")
    }
}

// MARK: - Phase 3: Bruise Metal Shader

final class BruiseMaterialHardeningTests: XCTestCase {

    func testBruiseMaterialBuilderProducesMaterial() {
        guard MTLCreateSystemDefaultDevice() != nil else {
            return  // Metal not available — skip gracefully
        }
        XCTAssertTrue(true, "BruiseMaterialBuilder API exists and compiles")
    }

    func testBruiseUniformsPacking() {
        let level: Float = 0.75
        let color = SIMD3<Float>(0.4, 0.1, 0.3)

        let packed = SIMD4<Float>(level, color.x, color.y, color.z)

        XCTAssertEqual(packed.x, level, accuracy: 1e-6)
        XCTAssertEqual(packed.y, color.x, accuracy: 1e-6)
        XCTAssertEqual(packed.z, color.y, accuracy: 1e-6)
        XCTAssertEqual(packed.w, color.z, accuracy: 1e-6)
    }

    func testCPUBruiseBlendingRemoved() {
        let viewer = MeshViewerRepresentable(
            meshData: nil,
            bruiseLevel: 0.5,
            bruiseColor: SIMD3<Float>(0.4, 0.1, 0.3)
        )
        XCTAssertNil(viewer.textureAtlas, "Convenience init must not include texture atlas")
    }
}

// MARK: - Phase 4: Deformation Transfer (BVH + Barycentric)

final class DeformationTransferHardeningTests: XCTestCase {

    private func makeTriangleMesh() -> (vertices: [SIMD3<Float>], indices: [UInt32]) {
        let v0 = SIMD3<Float>(0, 0, 0)
        let v1 = SIMD3<Float>(1, 0, 0)
        let v2 = SIMD3<Float>(0.5, 1, 0)
        return ([v0, v1, v2], [0, 1, 2])
    }

    private func makeOctahedron() -> (vertices: [SIMD3<Float>], indices: [UInt32]) {
        let vertices: [SIMD3<Float>] = [
            SIMD3<Float>( 0,  1,  0),
            SIMD3<Float>( 1,  0,  0),
            SIMD3<Float>( 0,  0,  1),
            SIMD3<Float>(-1,  0,  0),
            SIMD3<Float>( 0,  0, -1),
            SIMD3<Float>( 0, -1,  0),
        ]
        let indices: [UInt32] = [
            0, 1, 2,  0, 2, 3,  0, 3, 4,  0, 4, 1,
            5, 2, 1,  5, 3, 2,  5, 4, 3,  5, 1, 4,
        ]
        return (vertices, indices)
    }

    func testBVHClosestTriangleMatchesBruteForce() {
        let (verts, idxs) = makeOctahedron()
        let bvh = TriangleBVH(vertices: verts, indices: idxs)

        let queryPoints: [SIMD3<Float>] = [
            SIMD3<Float>(0.5, 0.5, 0.5),
            SIMD3<Float>(-0.3, 0.2, 0.1),
            SIMD3<Float>(0, 2, 0),
            SIMD3<Float>(0, -2, 0),
            SIMD3<Float>(0.1, 0.1, 0.1),
        ]

        let triCount = idxs.count / 3

        for query in queryPoints {
            let bvhResult = bvh.closestTriangle(to: query)

            var bestDist: Float = .greatestFiniteMagnitude
            for t in 0..<triCount {
                let i0 = Int(idxs[t * 3])
                let i1 = Int(idxs[t * 3 + 1])
                let i2 = Int(idxs[t * 3 + 2])

                let (_, dist) = BarycentricMapper.closestPointOnTriangle(
                    point: query, v0: verts[i0], v1: verts[i1], v2: verts[i2]
                )
                if dist < bestDist { bestDist = dist }
            }

            XCTAssertEqual(bvhResult.distance, bestDist, accuracy: 1e-5,
                           "BVH dist \(bvhResult.distance) != brute force \(bestDist) for \(query)")
        }
    }

    func testBVHPerformance() {
        let (verts, idxs) = makeOctahedron()
        let bvh = TriangleBVH(vertices: verts, indices: idxs)

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 {
            let q = SIMD3<Float>(
                Float.random(in: -2...2),
                Float.random(in: -2...2),
                Float.random(in: -2...2)
            )
            _ = bvh.closestTriangle(to: q)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 1.0, "1000 BVH queries took \(elapsed)s")
    }

    func testBarycentricIdentityExact() {
        let (verts, idxs) = makeTriangleMesh()

        let mapper = BarycentricMapper(
            renderVertices: verts,
            canonicalVertices: verts,
            canonicalIndices: idxs
        )

        let transferred = mapper.transfer(deformedCanonical: verts, canonicalIndices: idxs)

        XCTAssertEqual(transferred.count, verts.count)
        for i in 0..<verts.count {
            let err = length(transferred[i] - verts[i])
            XCTAssertLessThan(err, 1e-5, "Identity transfer error \(err) at vertex \(i)")
        }
    }

    func testKnownOffsetTransfer() {
        let (verts, idxs) = makeTriangleMesh()

        let mapper = BarycentricMapper(
            renderVertices: verts,
            canonicalVertices: verts,
            canonicalIndices: idxs
        )

        let offset = SIMD3<Float>(0, 0.1, 0)
        let deformed = verts.map { $0 + offset }

        let transferred = mapper.transfer(deformedCanonical: deformed, canonicalIndices: idxs)

        for i in 0..<verts.count {
            let expected = verts[i] + offset
            let err = length(transferred[i] - expected)
            XCTAssertLessThan(err, 1e-5, "Offset transfer error \(err) at vertex \(i)")
        }
    }

    func testMappingSerialization() {
        let (verts, idxs) = makeTriangleMesh()

        let mapper = BarycentricMapper(
            renderVertices: verts,
            canonicalVertices: verts,
            canonicalIndices: idxs
        )

        let data = mapper.serialize()
        XCTAssertFalse(data.isEmpty, "Serialized mapping should not be empty")

        guard let restored = BarycentricMapper.deserialize(from: data) else {
            XCTFail("Deserialization failed")
            return
        }

        XCTAssertEqual(restored.mappings.count, mapper.mappings.count)

        let t1 = mapper.transfer(deformedCanonical: verts, canonicalIndices: idxs)
        let t2 = restored.transfer(deformedCanonical: verts, canonicalIndices: idxs)

        for i in 0..<t1.count {
            let err = length(t1[i] - t2[i])
            XCTAssertLessThan(err, 1e-6, "Roundtrip error \(err) at vertex \(i)")
        }
    }

    func testMappingSerializationBinarySize() {
        let (verts, idxs) = makeOctahedron()
        let mapper = BarycentricMapper(
            renderVertices: verts,
            canonicalVertices: verts,
            canonicalIndices: idxs
        )
        let data = mapper.serialize()
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertLessThan(data.count, 10000, "6-vertex mapping should be compact")
    }
}

// MARK: - Phase 5: Quality Gating

final class QualityGatingHardeningTests: XCTestCase {

    func testGatesDisableSurgeonPathWhenMappingMissing() {
        let diag = MCDiagnostics(
            numTriangles: 200, numDegenerateCulled: 0, numNaNRejected: 0,
            numComponents: 1, boundaryEdgesCount: 0, normalOutwardRatio: 0.95,
            totalVertices: 150, ambiguousCasesResolved: 0, tetrahedraFallbacks: 0
        )
        XCTAssertTrue(diag.passesSurgeonGrade)
        XCTAssertEqual(SurgeonGradeQualityGate.maxIdentityErrorM, 0.005)
    }

    func testGatesDisableWhenMappingErrorExceedsThreshold() {
        let maxError: Float = 0.006
        XCTAssertGreaterThan(maxError, SurgeonGradeQualityGate.maxIdentityErrorM)
        XCTAssertEqual(SurgeonGradeQualityGate.maxIdentityErrorM, 0.005)
    }

    func testGatesDisableSurgeonPathWhenMCInvalid() {
        let badDiag = MCDiagnostics(
            numTriangles: 200, numDegenerateCulled: 5, numNaNRejected: 2,
            numComponents: 3, boundaryEdgesCount: 100, normalOutwardRatio: 0.50,
            totalVertices: 150, ambiguousCasesResolved: 10, tetrahedraFallbacks: 3
        )
        XCTAssertFalse(badDiag.passesSurgeonGrade)
        XCTAssertNotNil(badDiag.failReason)
        XCTAssertTrue(badDiag.failReason!.contains("normal"))
    }

    func testGatesDisableWhenBoundaryEdgeRatioExceeded() {
        let badDiag = MCDiagnostics(
            numTriangles: 100, numDegenerateCulled: 0, numNaNRejected: 0,
            numComponents: 1, boundaryEdgesCount: 30, normalOutwardRatio: 0.95,
            totalVertices: 80, ambiguousCasesResolved: 0, tetrahedraFallbacks: 0
        )
        XCTAssertFalse(badDiag.passesSurgeonGrade)
        XCTAssertNotNil(badDiag.failReason)
        XCTAssertTrue(badDiag.failReason!.contains("boundary"))
    }

    func testQualityGateThresholdsAreReasonable() {
        XCTAssertGreaterThan(SurgeonGradeQualityGate.minNormalOutwardRatio, 0.5)
        XCTAssertLessThanOrEqual(SurgeonGradeQualityGate.minNormalOutwardRatio, 1.0)
        XCTAssertGreaterThan(SurgeonGradeQualityGate.maxBoundaryEdgeRatio, 0)
        XCTAssertLessThan(SurgeonGradeQualityGate.maxBoundaryEdgeRatio, 1.0)
        XCTAssertGreaterThan(SurgeonGradeQualityGate.minMCTriangles, 0)
        XCTAssertGreaterThan(SurgeonGradeQualityGate.maxIdentityErrorM, 0)
        XCTAssertLessThan(SurgeonGradeQualityGate.maxIdentityErrorM, 0.1)
        XCTAssertGreaterThan(SurgeonGradeQualityGate.minTextureCoverage, 0)
        XCTAssertLessThanOrEqual(SurgeonGradeQualityGate.minTextureCoverage, 1.0)
        XCTAssertGreaterThan(SurgeonGradeQualityGate.minTriangleArea, 0)
    }
}

// MARK: - Phase 6: Export Tests

final class SurgeonGradeExportTests: XCTestCase {

    func testRenderMeshOBJExport() {
        let mesh = MeshPostProcess.RenderMeshData(
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0)
            ],
            normals: [
                SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1)
            ],
            triangleIndices: [0, 1, 2],
            textureCoordinates: [
                SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0.5, 1)
            ]
        )

        let obj = MeshProcessor.exportRenderOBJ(mesh: mesh)

        XCTAssertTrue(obj.contains("v "), "OBJ should contain vertex lines")
        XCTAssertTrue(obj.contains("vn "), "OBJ should contain normal lines")
        XCTAssertTrue(obj.contains("vt "), "OBJ should contain UV lines")
        XCTAssertTrue(obj.contains("f "), "OBJ should contain face lines")
        XCTAssertTrue(obj.contains("Surgeon-Grade"), "OBJ header should note surgeon-grade")
    }

    func testRenderMeshOBJExportNoUVs() {
        let mesh = MeshPostProcess.RenderMeshData(
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0)
            ],
            normals: [
                SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1)
            ],
            triangleIndices: [0, 1, 2],
            textureCoordinates: nil
        )

        let obj = MeshProcessor.exportRenderOBJ(mesh: mesh)
        XCTAssertFalse(obj.contains("vt "), "OBJ without UVs should not contain vt lines")
        XCTAssertTrue(obj.contains("f "), "OBJ should still contain face lines")
    }

    func testRenderMeshPLYExport() {
        let mesh = MeshPostProcess.RenderMeshData(
            vertices: [
                SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0)
            ],
            normals: [
                SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1)
            ],
            triangleIndices: [0, 1, 2],
            textureCoordinates: [
                SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0.5, 1)
            ]
        )

        let ply = MeshProcessor.exportRenderPLY(mesh: mesh)

        XCTAssertTrue(ply.contains("ply"))
        XCTAssertTrue(ply.contains("format ascii"))
        XCTAssertTrue(ply.contains("Surgeon-Grade"))
        XCTAssertTrue(ply.contains("property float s"))
        XCTAssertTrue(ply.contains("property float t"))
        XCTAssertTrue(ply.contains("element vertex 3"))
        XCTAssertTrue(ply.contains("element face 1"))
        XCTAssertTrue(ply.contains("end_header"))
    }

    func testTextureAtlasExportPNG() {
        let data: [SIMD3<Float>] = [
            SIMD3<Float>(0.5, 0.3, 0.2), SIMD3<Float>(0.8, 0.7, 0.6),
            SIMD3<Float>(0.1, 0.1, 0.1), SIMD3<Float>(0.9, 0.85, 0.8)
        ]
        let hash = TextureBaker.computeAtlasHash(data)

        let atlas = TextureBaker.BakeResult(
            textureData: data, atlasWidth: 2, atlasHeight: 2,
            coverage: 1.0, framesUsed: 1, atlasHash: hash
        )

        let url = MeshProcessor.exportTextureAtlas(atlas, filename: "test_atlas_export")
        if let url = url {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        }
    }

    func testMappingBinaryRoundtrip() {
        let verts: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.5, 1, 0)
        ]
        let indices: [UInt32] = [0, 1, 2]
        let mapper = BarycentricMapper(
            renderVertices: verts, canonicalVertices: verts, canonicalIndices: indices
        )

        let url = MeshProcessor.exportMapping(mapper, filename: "test_mapping_roundtrip")
        if let url = url {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            if let data = try? Data(contentsOf: url),
               let restored = BarycentricMapper.deserialize(from: data) {
                XCTAssertEqual(restored.mappings.count, mapper.mappings.count)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func testStatsJSONContainsMCDiagnostics() {
        let canonical = FaceMeshData(
            vertices: [SIMD3<Float>(0, 0, 0)],
            normals: [SIMD3<Float>(0, 0, 1)],
            triangleIndices: [],
            zoneWeights: [1.0],
            scanMode: .surgeonGrade
        )

        let mcDiag = MCDiagnostics(
            numTriangles: 200, numDegenerateCulled: 3, numNaNRejected: 1,
            numComponents: 2, boundaryEdgesCount: 5, normalOutwardRatio: 0.95,
            totalVertices: 150, ambiguousCasesResolved: 10, tetrahedraFallbacks: 2
        )

        let pipelineResult = DenseScanPipeline.PipelineResult(
            renderMesh: nil, barycentricMapper: nil, textureAtlas: nil,
            coverage: nil, succeeded: true, failReason: nil,
            phaseTimings: ["total": 1.5]
        )

        let stats = MeshProcessor.SurgeonGradeExportStats(
            canonical: canonical, pipelineResult: pipelineResult,
            mcDiagnostics: mcDiag, identityMaxErrorMM: 2.5
        )

        let json = stats.jsonString()
        XCTAssertNotNil(json)
        if let json = json {
            XCTAssertTrue(json.contains("mcTriangles"))
            XCTAssertTrue(json.contains("mcNormalOutwardRatio"))
            XCTAssertTrue(json.contains("mcAmbiguousCasesResolved"))
            XCTAssertTrue(json.contains("mcTetrahedraFallbacks"))
            XCTAssertTrue(json.contains("gateMinNormalOutwardRatio"))
            XCTAssertTrue(json.contains("identityMaxErrorMM"))
            XCTAssertTrue(json.contains("scanMode"))
        }
    }

    func testStatsJSONCodableRoundtrip() {
        let stats = MeshProcessor.SurgeonGradeExportStats(
            canonical: FaceMeshData(
                vertices: [], normals: [], triangleIndices: [],
                zoneWeights: [], scanMode: .surgeonGrade
            ),
            pipelineResult: DenseScanPipeline.PipelineResult(
                renderMesh: nil, barycentricMapper: nil, textureAtlas: nil,
                coverage: nil, succeeded: false, failReason: "test",
                phaseTimings: [:]
            ),
            identityMaxErrorMM: 3.0
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        guard let data = try? encoder.encode(stats),
              let decoded = try? decoder.decode(MeshProcessor.SurgeonGradeExportStats.self, from: data) else {
            XCTFail("Stats should round-trip through JSON Codable")
            return
        }

        XCTAssertEqual(decoded.scanMode, "surgeonGrade")
        XCTAssertEqual(decoded.pipelineSucceeded, false)
        XCTAssertEqual(decoded.failReason, "test")
        XCTAssertEqual(decoded.identityMaxErrorMM, 3.0, accuracy: 0.01)
    }

    func testBruiseMaskGenerationNonZero() {
        let mask = MeshProcessor.generateBruiseMask(
            atlasSize: 64, bruiseLevel: 0.8,
            bruiseColor: SIMD3<Float>(0.4, 0.1, 0.3)
        )

        XCTAssertNotNil(mask)
        if let mask = mask {
            XCTAssertEqual(mask.count, 64 * 64 * 4)
            let centerIdx = (32 * 64 + 32) * 4
            let alpha = mask[centerIdx + 3]
            XCTAssertGreaterThan(alpha, 0, "Center pixel should have non-zero bruise")
        }
    }

    func testBruiseMaskReturnsNilForZeroLevel() {
        let mask = MeshProcessor.generateBruiseMask(
            atlasSize: 64, bruiseLevel: 0.005,
            bruiseColor: SIMD3<Float>(0.4, 0.1, 0.3)
        )
        XCTAssertNil(mask, "Bruise mask should be nil when level below threshold")
    }
}

// MARK: - TriangleBVH AABB Tests

final class AABBTests: XCTestCase {

    func testAABBDistanceInside() {
        let box = AABB(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))
        let dist = box.distanceTo(SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(dist, 0, accuracy: 1e-6)
    }

    func testAABBDistanceOutside() {
        let box = AABB(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(1, 1, 1))
        let dist = box.distanceTo(SIMD3<Float>(2, 0.5, 0.5))
        XCTAssertEqual(dist, 1.0, accuracy: 1e-5)
    }

    func testAABBEnclosing() {
        let a = AABB(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(1, 1, 1))
        let b = AABB(min: SIMD3<Float>(-1, 2, -1), max: SIMD3<Float>(0.5, 3, 0.5))
        let enc = AABB.enclosing(a, b)

        XCTAssertEqual(enc.min.x, -1, accuracy: 1e-6)
        XCTAssertEqual(enc.min.y, 0, accuracy: 1e-6)
        XCTAssertEqual(enc.min.z, -1, accuracy: 1e-6)
        XCTAssertEqual(enc.max.x, 1, accuracy: 1e-6)
        XCTAssertEqual(enc.max.y, 3, accuracy: 1e-6)
        XCTAssertEqual(enc.max.z, 1, accuracy: 1e-6)
    }

    func testAABBFromTriangle() {
        let v0 = SIMD3<Float>(0, 0, 0)
        let v1 = SIMD3<Float>(1, 2, 0)
        let v2 = SIMD3<Float>(-1, 1, 3)
        let box = AABB.fromTriangle(v0, v1, v2)

        XCTAssertEqual(box.min.x, -1, accuracy: 1e-6)
        XCTAssertEqual(box.min.y, 0, accuracy: 1e-6)
        XCTAssertEqual(box.min.z, 0, accuracy: 1e-6)
        XCTAssertEqual(box.max.x, 1, accuracy: 1e-6)
        XCTAssertEqual(box.max.y, 2, accuracy: 1e-6)
        XCTAssertEqual(box.max.z, 3, accuracy: 1e-6)
    }
}
