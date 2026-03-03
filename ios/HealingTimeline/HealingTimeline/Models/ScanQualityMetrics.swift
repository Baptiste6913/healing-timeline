import Foundation
import simd

// MARK: - Scan Mode

/// Describes how the mesh was acquired.
enum ScanMode: String, Codable, Equatable {
    case demo              // Procedural sample mesh
    case coarseStable      // ARKit face tracking, multi-frame stabilised
    case depthCorrected    // Depth-map refined (Tier 2, feature-flagged)
    case surgeonGrade      // Hybrid 3D: dense ROI + TSDF + texture baking
}

// MARK: - Quality Metrics

/// Quantitative QA payload attached to every captured mesh.
struct ScanQualityMetrics: Codable, Equatable {

    // -- Aggregation -----------------------------------------------------------
    let framesCollected: Int       // total frames in buffer at capture time
    let framesUsed: Int            // frames surviving the trim
    let trimPercent: Float         // fraction removed on each tail (e.g. 0.10)

    // -- Jitter ----------------------------------------------------------------
    let meanFrameRMS: Float        // mean of consecutive-frame RMS (meters)
    let convergenceRMS: Float      // RMS between final aggregated mesh and last raw frame

    // -- Pose stability --------------------------------------------------------
    let poseRotationStdDeg: Float  // std-dev of Euler rotation magnitude (degrees)
    let poseTranslationStdMM: Float // std-dev of translation magnitude (mm)

    // -- Depth instrumentation (Tier 2) ----------------------------------------
    let depthFramesAvailable: Int  // how many frames had non-nil capturedDepthData
    let depthCorrectionApplied: Bool

    /// Original AVDepthData pixel format type (e.g. "dpth" for DepthFloat32, "hdis" for DisparityFloat32).
    let depthDataType: String

    /// Depth map resolution (width).
    let depthResolutionW: Int

    /// Depth map resolution (height).
    let depthResolutionH: Int

    /// Effective depth capture rate during scan.
    let depthFramesPerSecond: Float

    // -- Registration diagnostics (Gate 5) -------------------------------------

    /// Median absolute error on nose+midface ROI (mm).
    let registrationMedianAbsErrorMm: Float

    /// MAD (Median Absolute Deviation) on nose+midface ROI (mm).
    let registrationMADAbsErrorMm: Float

    /// Signed bias (mean signed error) on ROI (mm). Positive = depth reads farther.
    let registrationBiasMm: Float

    // -- Depth accuracy / quality (Tier 2.5) ------------------------------------

    /// AVDepthData accuracy ("absolute" or "relative").
    let depthDataAccuracy: String

    /// AVDepthData quality ("high" or "low").
    let depthDataQuality: String

    /// Whether Apple's depth noise filtering was applied.
    let isDepthDataFiltered: Bool

    /// Median pixel error from ARCamera vs manual projection cross-check (pixels).
    let crosscheckPixelErrorMedian: Float

    // -- Context ---------------------------------------------------------------
    let scanDurationSeconds: Float
    let deviceModel: String
    let scanMode: ScanMode
    let timestamp: Date

    // -- Helpers ---------------------------------------------------------------

    /// Overall quality grade for UI badge.
    var grade: ScanGrade {
        if scanMode == .demo { return .demo }
        if meanFrameRMS > 0.002 { return .poor }        // > 2 mm jitter
        if poseRotationStdDeg > 3.0 { return .poor }    // too much head movement
        if framesUsed < 20 { return .acceptable }
        if meanFrameRMS < 0.0008 && poseRotationStdDeg < 1.0 { return .excellent }
        return .good
    }

    /// Returns a JSON-serialised string (pretty-printed).
    func jsonString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Grade enum

enum ScanGrade: String, Codable {
    case demo
    case poor
    case acceptable
    case good
    case excellent

    var label: String {
        switch self {
        case .demo:       return "DEMO"
        case .poor:       return "POOR"
        case .acceptable: return "OK"
        case .good:       return "GOOD"
        case .excellent:  return "EXCELLENT"
        }
    }
}
