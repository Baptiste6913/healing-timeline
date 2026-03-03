import Foundation
import simd
import ARKit
import AVFoundation

// MARK: - Depth Reference Projection

/// A reference projection computed via ARCamera.projectPoint during bundle creation.
/// Used to cross-validate our manual projection pipeline against Apple's implementation.
/// Coordinates are in **depth buffer native pixel space** (not UI viewport space).
struct DepthReferenceProjection {
    let vertexFaceLocal: SIMD3<Float>
    let depthPixelU: Float
    let depthPixelV: Float
}

// MARK: - Cross-Validation Result

/// Result of comparing ARCamera.projectPoint vs our manual projection pipeline.
struct CrossValidationResult: Codable, Equatable {
    let medianPixelError: Float
    let passed: Bool
    let samplesUsed: Int

    static let zero = CrossValidationResult(medianPixelError: 0, passed: false, samplesUsed: 0)
}

// MARK: - Depth Bundle

/// One frame's depth payload with full calibration data.
struct DepthBundle {
    let depthMap: CVPixelBuffer          // Always kCVPixelFormatType_DepthFloat32 (meters)
    let intrinsics: simd_float3x3        // Camera intrinsics rescaled to depth map resolution
    let depthResolution: SIMD2<Int>      // (width, height) of depth map
    let timestamp: TimeInterval          // ARFrame.timestamp
    let faceTransform: simd_float4x4     // ARFaceAnchor.transform for this frame
    let cameraTransform: simd_float4x4   // ARFrame.camera.transform for this frame
    let originalDepthDataType: OSType    // kCVPixelFormatType_DepthFloat32 or kCVPixelFormatType_DisparityFloat32

    /// Pixel size in mm from camera calibration, if available.
    let pixelSizeMM: Float?

    // -- Accuracy / quality / filter metadata (Tier 2.5) ----------------------

    /// AVDepthData.depthDataAccuracy: "absolute" or "relative".
    /// "relative" means depth values are NOT in absolute meters — Tier 2 must be disabled.
    let depthDataAccuracy: String

    /// AVDepthData.depthDataQuality: "high" or "low".
    let depthDataQuality: String

    /// Whether Apple's built-in noise filtering was applied (AVDepthData.isDepthDataFiltered).
    let isDepthDataFiltered: Bool

    // -- Extrinsics (Tier 2.5) ------------------------------------------------

    /// Extrinsic matrix from RGB camera to depth camera coordinate system (4 cols × 3 rows).
    /// From `AVCameraCalibrationData.extrinsicMatrix`. nil if calibration data unavailable.
    let extrinsicMatrix: simd_float4x3?

    // -- Cross-validation references (Tier 2.5) --------------------------------

    /// Reference projections computed via `ARCamera.projectPoint` during bundle creation.
    /// Coordinates are in depth buffer native pixel space.
    let referenceProjections: [DepthReferenceProjection]?
}

// MARK: - Registration Diagnostics

/// Detailed registration diagnostics for Gate 5 (registration sanity).
struct RegistrationDiagnostics: Codable, Equatable {
    let medianAbsErrorMm: Float
    let madAbsErrorMm: Float    // Median Absolute Deviation
    let biasMm: Float           // signed: positive = depth reads farther than expected
    let samplesUsed: Int
    let passed: Bool

    static let zero = RegistrationDiagnostics(
        medianAbsErrorMm: 0, madAbsErrorMm: 0, biasMm: 0, samplesUsed: 0, passed: false
    )
}

// MARK: - Depth Correction Service

/// Tier-2 depth-map vertex correction.
///
/// **Always behind `FeatureFlags.depthCorrectionEnabled`.**
/// Includes built-in acceptance gates that auto-disable the correction
/// when depth data is missing, unreliable, or registration fails sanity checks.
///
/// ## Gate order
/// 1. **Feature flag** — `FeatureFlags.depthCorrectionEnabled`
/// 2. **Frame ratio** — ≥50% of frames must have depth
/// 3. **Accuracy** — `depthDataAccuracy == .relative` → disable
/// 4. **Quality** — all frames `depthDataQuality == .low` → disable
/// 5. **Registration** — median/MAD/bias on nose+midface ROI
/// 6. **Cross-validation** — ARCamera.projectPoint vs manual pipeline, median pixel error ≤ threshold
enum DepthCorrectionService {

    // MARK: - Public API

    struct CorrectionResult {
        let correctedVertices: [SIMD3<Float>]
        let framesApplied: Int
        let meanDeltaMM: Float
        let autoDisabled: Bool
        let autoDisableReason: String?
        let registrationDiagnostics: RegistrationDiagnostics
        let crossValidation: CrossValidationResult?
    }

    /// Attempt depth correction on aggregated vertices.
    ///
    /// - Parameters:
    ///   - vertices: Trimmed-mean aggregated vertex positions (meters, ARKit face space).
    ///   - depthBundles: Per-frame depth bundles collected during scan (already converted to Float32 meters).
    /// - Returns: `CorrectionResult` with corrected vertices or auto-disable info.
    static func correct(
        vertices: [SIMD3<Float>],
        depthBundles: [DepthBundle],
        faceTransforms: [simd_float4x4],
        frameTransforms: [simd_float4x4]
    ) -> CorrectionResult {

        // ── Gate 1: feature flag ──────────────────────────────────────────
        guard FeatureFlags.depthCorrectionEnabled else {
            return disabled(vertices: vertices, reason: "Depth correction feature flag is OFF")
        }

        // ── Gate 2: enough depth frames? ──────────────────────────────────
        let totalFrames = faceTransforms.count
        guard totalFrames > 0 else {
            return disabled(vertices: vertices, reason: "No frames provided")
        }
        let depthRatio = Float(depthBundles.count) / Float(totalFrames)
        guard depthRatio >= FeatureFlags.depthMinFrameRatio else {
            let pct = String(format: "%.0f", depthRatio * 100)
            return disabled(
                vertices: vertices,
                reason: "Only \(pct)% of frames have depth (need \(Int(FeatureFlags.depthMinFrameRatio * 100))%)"
            )
        }

        // ── Gate 3: accuracy — .relative means NOT absolute meters ────────
        let hasRelative = depthBundles.contains { $0.depthDataAccuracy == "relative" }
        if hasRelative {
            print("[DepthCorrection] Gate3-Accuracy: depthDataAccuracy == .relative detected")
            return disabled(
                vertices: vertices,
                reason: "depthDataAccuracy is .relative — depth values not in absolute meters"
            )
        }

        // ── Gate 4: quality — if ALL bundles are .low, disable ────────────
        let allLowQuality = depthBundles.allSatisfy { $0.depthDataQuality == "low" }
        if allLowQuality && !depthBundles.isEmpty {
            print("[DepthCorrection] Gate4-Quality: all depth frames have quality == .low")
            return disabled(
                vertices: vertices,
                reason: "All depth frames have depthDataQuality == .low"
            )
        }

        // ── Gate 5: registration sanity (median/MAD/bias on ROI) ─────────
        let diagnostics = computeRegistrationDiagnostics(
            vertices: vertices,
            depthBundles: depthBundles
        )

        let g5Log = String(format: "[DepthCorrection] Gate5-Registration: median=%.3fmm MAD=%.3fmm bias=%.3fmm samples=%d",
                           diagnostics.medianAbsErrorMm, diagnostics.madAbsErrorMm,
                           diagnostics.biasMm, diagnostics.samplesUsed)
        print(g5Log)

        if !diagnostics.passed {
            var reasons: [String] = []
            if diagnostics.samplesUsed == 0 {
                reasons.append("no valid registration samples")
            }
            if diagnostics.medianAbsErrorMm > FeatureFlags.depthRegistrationMedianMaxMm {
                reasons.append(String(format: "median %.2fmm > %.1fmm",
                                      diagnostics.medianAbsErrorMm, FeatureFlags.depthRegistrationMedianMaxMm))
            }
            if diagnostics.madAbsErrorMm > FeatureFlags.depthRegistrationMADMaxMm {
                reasons.append(String(format: "MAD %.2fmm > %.1fmm",
                                      diagnostics.madAbsErrorMm, FeatureFlags.depthRegistrationMADMaxMm))
            }
            if abs(diagnostics.biasMm) > FeatureFlags.depthRegistrationBiasMaxMm {
                reasons.append(String(format: "|bias| %.2fmm > %.1fmm",
                                      abs(diagnostics.biasMm), FeatureFlags.depthRegistrationBiasMaxMm))
            }
            return disabled(
                vertices: vertices,
                reason: "Registration failed: \(reasons.joined(separator: ", "))",
                diagnostics: diagnostics
            )
        }

        print("[DepthCorrection] Registration check PASSED")

        // ── Gate 6: cross-validation (ARCamera vs manual projection) ──────
        let crossVal = crossValidateProjection(bundles: depthBundles)

        if crossVal.samplesUsed > 0 {
            let cvLog = String(format: "[DepthCorrection] Gate6-CrossValidation: medianPxError=%.2fpx samples=%d passed=%@",
                               crossVal.medianPixelError, crossVal.samplesUsed,
                               crossVal.passed ? "YES" : "NO")
            print(cvLog)

            if !crossVal.passed {
                return disabled(
                    vertices: vertices,
                    reason: String(format: "Cross-validation failed: median pixel error %.2fpx > %.1fpx threshold",
                                   crossVal.medianPixelError, FeatureFlags.crossValidationMaxPixelError),
                    diagnostics: diagnostics,
                    crossValidation: crossVal
                )
            }
        }

        // ── Correction pass ───────────────────────────────────────────────
        let (corrected, totalDelta, appliedCount) = applyCorrection(
            vertices: vertices,
            depthBundles: depthBundles
        )

        let meanDeltaMM = appliedCount > 0 ? (totalDelta / Float(appliedCount)) * 1000 : 0

        print("[DepthCorrection] Applied to \(appliedCount)/\(vertices.count) vertices, mean delta: \(String(format: "%.3f", meanDeltaMM))mm")

        return CorrectionResult(
            correctedVertices: corrected,
            framesApplied: depthBundles.count,
            meanDeltaMM: meanDeltaMM,
            autoDisabled: false,
            autoDisableReason: nil,
            registrationDiagnostics: diagnostics,
            crossValidation: crossVal.samplesUsed > 0 ? crossVal : nil
        )
    }

    // MARK: - Disparity → Depth Conversion

    /// Convert an AVDepthData to Float32 depth in meters.
    /// If already Float32 depth, returns depthDataMap directly.
    /// If disparity, converts via `converting(toDepthDataType:)`.
    static func ensureDepthFloat32(_ depthData: AVDepthData) -> (CVPixelBuffer, OSType) {
        let originalType = depthData.depthDataType
        let targetType = kCVPixelFormatType_DepthFloat32

        if originalType == targetType {
            return (depthData.depthDataMap, originalType)
        }

        // Convert disparity → depth (meters)
        let converted = depthData.converting(toDepthDataType: targetType)
        print("[DepthCorrection] Converted depthDataType \(fourCCString(originalType)) → DepthFloat32")
        return (converted.depthDataMap, originalType)
    }

    // MARK: - Intrinsics Rescale

    /// Rescale camera intrinsics from the reference dimensions to the actual depth map dimensions.
    ///
    /// Camera calibration intrinsics are expressed relative to `intrinsicMatrixReferenceDimensions`.
    /// The depth map is typically smaller (e.g. 256×192 vs 1920×1440).
    /// We scale fx, fy, cx, cy proportionally.
    static func rescaleIntrinsics(
        _ intrinsics: simd_float3x3,
        fromReferenceWidth refW: Float,
        fromReferenceHeight refH: Float,
        toDepthWidth depthW: Int,
        toDepthHeight depthH: Int
    ) -> simd_float3x3 {
        let scaleX = Float(depthW) / refW
        let scaleY = Float(depthH) / refH

        var scaled = intrinsics
        // Column 0: [fx, 0, 0]
        scaled[0][0] *= scaleX   // fx
        // Column 1: [0, fy, 0]
        scaled[1][1] *= scaleY   // fy
        // Column 2: [cx, cy, 1]
        scaled[2][0] *= scaleX   // cx
        scaled[2][1] *= scaleY   // cy

        return scaled
    }

    // MARK: - Vertex → Depth Pixel Projection

    /// Project a face-local vertex into depth map pixel coordinates.
    ///
    /// Pipeline: face-local → world (faceTransform) → RGB camera (cameraTransform⁻¹)
    ///           → depth camera (extrinsicMatrix, if non-nil) → depth pixel (rescaled intrinsics).
    ///
    /// All coordinates are in **depth buffer native pixel space** (not UI viewport space).
    ///
    /// Returns (u, v, expectedDepth) in depth-map pixel coords, or nil if behind camera.
    static func projectVertexToDepthPixel(
        vertex: SIMD3<Float>,
        bundle: DepthBundle
    ) -> (u: Float, v: Float, expectedDepth: Float)? {

        // face-local → world
        let worldPos = bundle.faceTransform * SIMD4<Float>(vertex, 1)

        // world → RGB camera
        let camInv = bundle.cameraTransform.inverse
        let rgbCamPos = camInv * worldPos

        // RGB camera → depth camera (if extrinsics available)
        let camPos: SIMD3<Float>
        if let ext = bundle.extrinsicMatrix {
            // simd_float4x3: 4 columns × 3 rows
            // result = ext[0]*x + ext[1]*y + ext[2]*z + ext[3]*w
            camPos = ext[0] * rgbCamPos.x
                   + ext[1] * rgbCamPos.y
                   + ext[2] * rgbCamPos.z
                   + ext[3] * rgbCamPos.w
        } else {
            camPos = SIMD3<Float>(rgbCamPos.x, rgbCamPos.y, rgbCamPos.z)
        }

        // Must be in front of camera
        guard camPos.z > 0.01 else { return nil }

        // Project with depth-rescaled intrinsics
        let fx = bundle.intrinsics[0][0]
        let fy = bundle.intrinsics[1][1]
        let cx = bundle.intrinsics[2][0]
        let cy = bundle.intrinsics[2][1]

        let u = fx * (camPos.x / camPos.z) + cx
        let v = fy * (camPos.y / camPos.z) + cy

        return (u, v, camPos.z)
    }

    // MARK: - Cross-Validation

    /// Compare ARCamera.projectPoint reference projections with our manual pipeline.
    ///
    /// Both sets of coordinates are in **depth buffer native pixel space**.
    /// Detects orientation/mirroring bugs that would cause the projection to land
    /// in a completely wrong location.
    ///
    /// - Parameter bundles: Depth bundles containing reference projections.
    /// - Returns: `CrossValidationResult` with median pixel error and pass/fail.
    static func crossValidateProjection(
        bundles: [DepthBundle]
    ) -> CrossValidationResult {

        var pixelErrors: [Float] = []

        for bundle in bundles {
            guard let refs = bundle.referenceProjections, !refs.isEmpty else { continue }

            for ref in refs {
                guard let proj = projectVertexToDepthPixel(
                    vertex: ref.vertexFaceLocal,
                    bundle: bundle
                ) else { continue }

                let dx = proj.u - ref.depthPixelU
                let dy = proj.v - ref.depthPixelV
                let error = sqrt(dx * dx + dy * dy)
                pixelErrors.append(error)
            }
        }

        guard !pixelErrors.isEmpty else {
            // No reference data available — pass by default (can't validate)
            return CrossValidationResult(medianPixelError: 0, passed: true, samplesUsed: 0)
        }

        let sorted = pixelErrors.sorted()
        let median = sorted[sorted.count / 2]
        let passed = median <= FeatureFlags.crossValidationMaxPixelError

        return CrossValidationResult(
            medianPixelError: median,
            passed: passed,
            samplesUsed: pixelErrors.count
        )
    }

    // MARK: - Timestamp-Based Nearest-Neighbor Matching

    /// Find the depth bundle closest in time to a given timestamp.
    static func nearestBundle(
        forTimestamp ts: TimeInterval,
        in bundles: [DepthBundle]
    ) -> DepthBundle? {
        guard !bundles.isEmpty else { return nil }
        var bestIdx = 0
        var bestDt = abs(bundles[0].timestamp - ts)
        for i in 1..<bundles.count {
            let dt = abs(bundles[i].timestamp - ts)
            if dt < bestDt {
                bestDt = dt
                bestIdx = i
            }
        }
        return bundles[bestIdx]
    }

    // MARK: - Bilinear Depth Sampling

    /// Bilinear sample of a Float32 depth buffer at sub-pixel coordinates.
    static func sampleDepth(
        buffer: CVPixelBuffer,
        u: Float, v: Float,
        width: Int, height: Int
    ) -> Float? {
        let x0 = Int(floor(u))
        let y0 = Int(floor(v))
        let x1 = x0 + 1
        let y1 = y0 + 1

        guard x0 >= 0, y0 >= 0, x1 < width, y1 < height else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let floatPtr = base.assumingMemoryBound(to: Float.self)

        func pixel(_ x: Int, _ y: Int) -> Float {
            let offset = y * (bytesPerRow / MemoryLayout<Float>.stride) + x
            return floatPtr[offset]
        }

        let fx = u - Float(x0)
        let fy = v - Float(y0)

        let d00 = pixel(x0, y0)
        let d10 = pixel(x1, y0)
        let d01 = pixel(x0, y1)
        let d11 = pixel(x1, y1)

        // Skip invalid depth values (0 or NaN)
        guard d00 > 0, d10 > 0, d01 > 0, d11 > 0,
              !d00.isNaN, !d10.isNaN, !d01.isNaN, !d11.isNaN else { return nil }

        let top = d00 * (1 - fx) + d10 * fx
        let bot = d01 * (1 - fx) + d11 * fx
        return top * (1 - fy) + bot * fy
    }

    // MARK: - Instrumentation

    /// Quick check: how many frames in a buffer have usable depth data?
    static func depthAvailabilityReport(frames: [ARFrame?]) -> (available: Int, total: Int, percent: Float) {
        let total = frames.count
        let available = frames.compactMap { $0?.capturedDepthData }.count
        let percent = total > 0 ? Float(available) / Float(total) * 100 : 0
        return (available, total, percent)
    }

    // MARK: - ROI Builder (internal, used by ScanViewModel for reference projections)

    /// Select ROI vertices: nose tip + midface (within 2cm of nose tip XY, forward Z).
    static func buildNoseMidfaceROI(vertices: [SIMD3<Float>]) -> [Int] {
        guard !vertices.isEmpty else { return [] }
        let tipIdx = findNoseTipIndex(vertices: vertices)
        let tipPos = vertices[tipIdx]

        var roi: [Int] = [tipIdx]
        let roiRadiusXY: Float = 0.02  // 2cm around nose tip in XY
        let minZ = tipPos.z - 0.015     // within 1.5cm behind tip

        for i in 0..<vertices.count where i != tipIdx {
            let v = vertices[i]
            let dXY = sqrt((v.x - tipPos.x) * (v.x - tipPos.x) + (v.y - tipPos.y) * (v.y - tipPos.y))
            if dXY < roiRadiusXY && v.z > minZ {
                roi.append(i)
            }
        }
        return roi
    }

    static func findNoseTipIndex(vertices: [SIMD3<Float>]) -> Int {
        var maxZ: Float = -.greatestFiniteMagnitude
        var idx = 0
        for i in 0..<vertices.count {
            if vertices[i].z > maxZ {
                maxZ = vertices[i].z
                idx = i
            }
        }
        return idx
    }

    // MARK: - Private: Registration Diagnostics

    /// Compute registration quality on a ROI (nose tip + midface vertices).
    /// Uses all depth bundles, projects ROI vertices, measures absolute error in mm.
    private static func computeRegistrationDiagnostics(
        vertices: [SIMD3<Float>],
        depthBundles: [DepthBundle]
    ) -> RegistrationDiagnostics {

        let roiIndices = buildNoseMidfaceROI(vertices: vertices)
        guard !roiIndices.isEmpty else {
            return RegistrationDiagnostics(
                medianAbsErrorMm: 999, madAbsErrorMm: 999, biasMm: 999, samplesUsed: 0, passed: false
            )
        }

        var signedErrors: [Float] = []  // in meters, signed (positive = depth > expected)

        for bundle in depthBundles {
            for vi in roiIndices {
                guard let proj = projectVertexToDepthPixel(vertex: vertices[vi], bundle: bundle) else {
                    continue
                }
                guard let sampledDepth = sampleDepth(
                    buffer: bundle.depthMap,
                    u: proj.u, v: proj.v,
                    width: bundle.depthResolution.x,
                    height: bundle.depthResolution.y
                ) else { continue }

                let error = sampledDepth - proj.expectedDepth
                signedErrors.append(error)
            }
        }

        guard !signedErrors.isEmpty else {
            return RegistrationDiagnostics(
                medianAbsErrorMm: 999, madAbsErrorMm: 999, biasMm: 999, samplesUsed: 0, passed: false
            )
        }

        let absErrors = signedErrors.map { abs($0) }
        let sortedAbs = absErrors.sorted()
        let medianAbs = sortedAbs[sortedAbs.count / 2]
        let medianAbsMm = medianAbs * 1000

        // MAD = median(|error - median(error)|)
        let sortedSigned = signedErrors.sorted()
        let medianSigned = sortedSigned[sortedSigned.count / 2]
        let deviations = signedErrors.map { abs($0 - medianSigned) }.sorted()
        let mad = deviations[deviations.count / 2]
        let madMm = mad * 1000

        // Bias = mean signed error
        let bias = signedErrors.reduce(0, +) / Float(signedErrors.count)
        let biasMm = bias * 1000

        let passed = signedErrors.count >= 3
            && medianAbsMm <= FeatureFlags.depthRegistrationMedianMaxMm
            && madMm <= FeatureFlags.depthRegistrationMADMaxMm
            && abs(biasMm) <= FeatureFlags.depthRegistrationBiasMaxMm

        return RegistrationDiagnostics(
            medianAbsErrorMm: medianAbsMm,
            madAbsErrorMm: madMm,
            biasMm: biasMm,
            samplesUsed: signedErrors.count,
            passed: passed
        )
    }

    // MARK: - Private: Correction Pass

    /// Apply depth correction using timestamp-matched bundles.
    private static func applyCorrection(
        vertices: [SIMD3<Float>],
        depthBundles: [DepthBundle]
    ) -> (corrected: [SIMD3<Float>], totalDelta: Float, appliedCount: Int) {

        var corrected = vertices
        var totalDelta: Float = 0
        var appliedCount = 0

        for vi in 0..<vertices.count {
            var depthDeltas: [Float] = []

            for bundle in depthBundles {
                guard let proj = projectVertexToDepthPixel(
                    vertex: vertices[vi], bundle: bundle
                ) else { continue }

                guard let sampledDepth = sampleDepth(
                    buffer: bundle.depthMap,
                    u: proj.u, v: proj.v,
                    width: bundle.depthResolution.x,
                    height: bundle.depthResolution.y
                ) else { continue }

                let delta = sampledDepth - proj.expectedDepth

                // Clamp per-frame delta
                let clamped = max(-FeatureFlags.depthClampDeltaM,
                                  min(FeatureFlags.depthClampDeltaM, delta))
                depthDeltas.append(clamped)
            }

            guard depthDeltas.count >= 3 else { continue }

            // Trimmed mean of depth deltas (reject outliers)
            let sorted = depthDeltas.sorted()
            let trimCount = max(1, sorted.count / 5)  // 20% trim
            let trimmed = Array(sorted[trimCount..<(sorted.count - trimCount)])
            guard !trimmed.isEmpty else { continue }

            let meanDelta = trimmed.reduce(0, +) / Float(trimmed.count)

            // Apply correction along camera Z → simplified to face-local Z
            corrected[vi].z += meanDelta

            totalDelta += abs(meanDelta)
            appliedCount += 1
        }

        return (corrected, totalDelta, appliedCount)
    }

    // MARK: - Private Helpers

    private static func disabled(
        vertices: [SIMD3<Float>],
        reason: String,
        diagnostics: RegistrationDiagnostics = .zero,
        crossValidation: CrossValidationResult? = nil
    ) -> CorrectionResult {
        print("[DepthCorrection] AUTO-DISABLED: \(reason)")
        return CorrectionResult(
            correctedVertices: vertices,
            framesApplied: 0,
            meanDeltaMM: 0,
            autoDisabled: true,
            autoDisableReason: reason,
            registrationDiagnostics: diagnostics,
            crossValidation: crossValidation
        )
    }

    private static func fourCCString(_ code: OSType) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}
