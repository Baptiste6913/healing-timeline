import Foundation

/// Centralised feature flags.  Tier 2 features are **off by default**
/// and must be explicitly enabled after acceptance gates pass.
enum FeatureFlags {

    // MARK: - Tier 2: Depth Correction

    private static let depthCorrectionKey = "feature_depthCorrection"

    /// Whether depth-map correction is enabled.
    /// Default: **false**.  Enable via Settings or programmatically after
    /// verifying that depth registration passes sanity checks.
    static var depthCorrectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: depthCorrectionKey) }
        set { UserDefaults.standard.set(newValue, forKey: depthCorrectionKey) }
    }

    // MARK: - Scan stabilisation

    /// Number of frames to collect during the stabilisation countdown.
    static let captureFrameTarget: Int = 60

    /// Trim percentage for the trimmed-mean aggregation (each tail).
    static let trimPercent: Float = 0.10

    /// Maximum frame-to-frame RMS (meters) before the countdown pauses.
    /// 0.5 mm is a practical threshold for TrueDepth jitter at arm's length.
    static let microMovementThresholdM: Float = 0.0005

    /// Duration of the stabilisation countdown in seconds.
    static let scanCountdownSeconds: Float = 3.0

    // MARK: - Tier 2: Depth Correction Parameters

    /// Maximum per-vertex depth correction delta per frame (meters).
    static let depthClampDeltaM: Float = 0.005   // 5 mm

    /// Minimum fraction of frames that must have depth data
    /// for the depth pipeline to be considered viable.
    static let depthMinFrameRatio: Float = 0.50

    // MARK: - Tier 2: Registration Gate Thresholds (Gate 3)

    /// Maximum allowed median absolute error on nose+midface ROI (mm).
    static let depthRegistrationMedianMaxMm: Float = 2.0

    /// Maximum allowed MAD (Median Absolute Deviation) on ROI (mm).
    static let depthRegistrationMADMaxMm: Float = 1.0

    /// Maximum allowed |bias| (mean signed error) on ROI (mm).
    static let depthRegistrationBiasMaxMm: Float = 1.0

    // MARK: - Tier 2: Cross-Validation (Gate 6)

    /// Maximum allowed median pixel error for ARCamera vs manual projection cross-validation.
    /// Measured in depth buffer native pixel space. 3px is generous enough to tolerate
    /// minor extrinsic offsets while catching gross orientation/mirroring bugs.
    static let crossValidationMaxPixelError: Float = 3.0

    // MARK: - Hybrid Scan 3D (Surgeon-Grade Pipeline)

    private static let hybridScan3DKey = "feature_hybridScan3D"

    /// Whether the hybrid 3D scan pipeline (dense ROI + texture baking) is enabled.
    /// Default: **false**. Requires depth correction to also be enabled.
    /// When on, triggers longer capture (8-14s), dense point cloud fusion,
    /// TSDF meshing, multi-view texture baking, and deformation transfer.
    static var hybridScan3DEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: hybridScan3DKey) }
        set { UserDefaults.standard.set(newValue, forKey: hybridScan3DKey) }
    }

    // MARK: - Hybrid Scan Parameters

    /// Dense capture countdown duration (seconds). Longer than coarse scan.
    static let denseCaptureCountdownSeconds: Float = 10.0

    /// Dense capture frame target.
    static let denseCaptureFrameTarget: Int = 300

    /// TSDF voxel size in meters (0.5mm default).
    static let tsdfVoxelSize: Float = 0.0005

    /// Point cloud fusion: minimum samples per voxel to emit.
    static let fusionMinSamplesPerVoxel: Int = 2

    /// Texture atlas resolution (pixels).
    static let textureAtlasSize: Int = 1024

    /// Minimum coverage score (0..1) for dense ROI to be accepted.
    static let minCoverageScore: Float = 0.50

    /// Minimum fused points for dense ROI to be accepted.
    static let minFusedPoints: Int = 500

    // MARK: - Healing Model V2

    private static let healingModelV2Key = "feature_healingModelV2"

    /// Whether the multi-compartment healing model (v2) is active.
    /// Default: **false**.  When off, the app uses the original bi-exponential model.
    static var healingModelV2Enabled: Bool {
        get { UserDefaults.standard.bool(forKey: healingModelV2Key) }
        set { UserDefaults.standard.set(newValue, forKey: healingModelV2Key) }
    }
}
