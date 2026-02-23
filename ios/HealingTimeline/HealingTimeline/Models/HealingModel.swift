import Foundation
import simd

/// Parametric bi-exponential + log-normal healing model.
/// See MODEL_CARD.md for equations and calibration.
///
/// DISCLAIMER: Illustrative simulation only. Not medical advice.
final class HealingModel {

    // MARK: - Swelling Parameters

    private let a1: Float = 0.6
    private let a2: Float = 0.4
    private let tau1: Float = 7.0
    private let tau2: Float    // set by profile
    private let intensityScale: Float

    // MARK: - Bruising Parameters

    private let tPeakBruise: Float = 2.5
    private let bruisingEnabled: Bool
    private let maxDisplacementMM: Float

    // MARK: - Bruise Color Keyframes

    private static let bruiseColors: [(Float, SIMD3<Float>)] = [
        (0,   SIMD3<Float>(0.40, 0.10, 0.30)),
        (3,   SIMD3<Float>(0.30, 0.10, 0.40)),
        (5,   SIMD3<Float>(0.20, 0.40, 0.20)),
        (8,   SIMD3<Float>(0.60, 0.60, 0.10)),
        (11,  SIMD3<Float>(0.70, 0.70, 0.30)),
        (14,  SIMD3<Float>(0.80, 0.80, 0.50)),
    ]

    private static let varianceMin: Float = 0.65
    private static let varianceMax: Float = 1.25

    // MARK: - Init

    init(profile: HealingProfile = HealingProfile()) {
        var baseTau2 = profile.skinThickness.slowDecayTau
        if let age = profile.age {
            if age < 30 { baseTau2 *= 0.9 }
            else if age > 50 { baseTau2 *= 1.1 }
        }
        self.tau2 = baseTau2
        self.intensityScale = profile.initialIntensity.scale
        self.bruisingEnabled = profile.bruisingPresent
        self.maxDisplacementMM = profile.initialIntensity.maxDisplacementMM
    }

    // MARK: - Swelling

    func swelling(at t: Float) -> Float {
        let s = a1 * exp(-t / tau1) + a2 * exp(-t / tau2)
        return min(max(s * intensityScale, 0), 1)
    }

    func swellingRange(at t: Float) -> (min: Float, median: Float, max: Float) {
        let med = swelling(at: t)
        let sMin = min(max(med * Self.varianceMin, 0), 1)
        let sMax = min(max(med * Self.varianceMax, 0), 1)
        return (sMin, med, sMax)
    }

    // MARK: - Bruising

    func bruising(at t: Float) -> Float {
        guard bruisingEnabled, t > 0 else { return 0 }
        let b = (t / tPeakBruise) * exp(1.0 - t / tPeakBruise)
        return min(max(b * intensityScale, 0), 1)
    }

    func bruiseColor(at t: Float) -> SIMD3<Float> {
        let colors = Self.bruiseColors
        guard t > 0 else { return colors[0].1 }

        for i in 0..<(colors.count - 1) {
            let (t0, c0) = colors[i]
            let (t1, c1) = colors[i + 1]
            if t >= t0 && t <= t1 {
                let frac = (t - t0) / (t1 - t0)
                return mix(c0, c1, t: frac)
            }
        }
        return colors.last!.1
    }

    // MARK: - Volume

    func nasalVolumeDelta(at t: Float) -> Float {
        return swelling(at: t) * maxDisplacementMM
    }

    // MARK: - Full Evaluation

    func evaluate(at t: Float) -> HealingState {
        let (sMin, sMed, sMax) = swellingRange(at: t)
        return HealingState(
            day: t,
            swellingLevel: sMed,
            swellingMin: sMin,
            swellingMax: sMax,
            bruisingLevel: bruising(at: t),
            bruiseColor: bruiseColor(at: t),
            nasalVolumeDelta: nasalVolumeDelta(at: t)
        )
    }

    // MARK: - Presets

    static let presetDays: [Float] = [0, 1, 3, 7, 14, 30, 90, 180, 365]

    func timeline() -> [HealingState] {
        return Self.presetDays.map { evaluate(at: $0) }
    }
}
