import Foundation
import simd

/// Multi-compartment parametric healing model (v2).
///
/// Compartments:
///   nasal_upper  — dorsum + sidewall, 2/3 of nasal envelope
///   nasal_tip    — tip + supra-tip, 1/3, delayed onset, slowest resolution
///   periorbital_edema  — fast cycle (peak J2, ≈0 at J8)
///   periorbital_bruise — fast cycle (97 % resolved at J10)
///
/// Hard constraints (medical literature):
///   • Periorbital edema: peak J2, ≈ 0 at J8
///   • Periorbital bruise: 97 % resolved J10
///   • Nasal (aggregate): 2/3 resolved 1 month, 95 % at 6 months, 97.5 % at 12 months
///   • Nasal total displacement peak: days 7–14
///   • Steroids: no benefit on nasal components beyond ~J7
///   • Tip bias: non-decreasing on [7, 90], stable (plateau) after
///
/// Time Origin / PRS Baseline Reconciliation:
///   T0 = surgical completion (end of procedure). All timepoints are days post-T0.
///   PRS literature baselines (1–2 weeks) are used as calibration anchors: the model
///   is fitted so that S_agg(30) ≈ 0.33, representing 2/3 resolved at 1 month.
///   The ramp-up from 0 to peak (days 0–7) models the progressive onset of edema
///   that is underway before clinical baseline measurement at 1–2 weeks.
///
/// DISCLAIMER: Illustrative simulation only. Not medical advice.
final class HealingModelV2 {

    // MARK: - Curve Parameters

    /// Nasal upper (dorsum) tri-exponential decay.
    private let aFast: Float
    private let aMed: Float
    private let aSlow: Float
    private let tauFast: Float
    private let tauMed: Float
    private let tauSlow: Float

    /// Nasal ramp-up time constant (days). Edema builds from 0 → peak over first days.
    private let nasalRampTau: Float

    /// Nasal tip onset and bias.
    private let tipImmediateRatio: Float    // fraction of immediate response at t = 0
    private let tipOnsetTau: Float          // onset ramp time constant (days)
    private let tipBiasGain: Float          // max additional retention ratio (non-decreasing)
    private let tipBiasTau: Float           // bias growth time constant (days)

    /// Periorbital edema parameters.
    private let periEdemaTpeak: Float
    private let periEdemaPower: Float
    private let periEdemaScale: Float

    /// Periorbital bruise parameters.
    private let periBruiseTpeak: Float
    private let periBruisePower: Float
    private let periBruiseScale: Float

    /// Steroid reduction for periorbital components (0 = no steroids, 0.25 = 25 % reduction).
    private let steroidPeriReduction: Float

    /// Steroid reduction for nasal fast component only (confined, short-lived).
    private let steroidNasalFastReduction: Float

    /// Steroid effect decay time constant (days). Short — effect negligible by ~J5.
    private let steroidDecayTau: Float

    /// Per-compartment max displacement (mm).
    private let maxDispUpperMM: Float
    private let maxDispTipMM: Float
    private let maxDispPeriMM: Float

    /// Uncertainty band multipliers.
    private let bandLow: Float
    private let bandHigh: Float

    /// Whether bruising is enabled.
    private let bruisingEnabled: Bool

    // MARK: - Bruise Color Keyframes (RGB 0-1)

    static let bruiseColorsV2: [(Float, SIMD3<Float>)] = [
        ( 0.0, SIMD3<Float>(0.45, 0.08, 0.30)),   // red-violet
        ( 1.0, SIMD3<Float>(0.35, 0.08, 0.40)),   // deep purple (peak intensity)
        ( 3.0, SIMD3<Float>(0.28, 0.12, 0.42)),   // blue-purple
        ( 5.0, SIMD3<Float>(0.18, 0.38, 0.18)),   // green
        ( 7.0, SIMD3<Float>(0.45, 0.55, 0.10)),   // yellow-green
        (10.0, SIMD3<Float>(0.65, 0.65, 0.30)),   // yellow-fade
        (14.0, SIMD3<Float>(0.80, 0.78, 0.55)),   // near-skin
    ]

    // MARK: - Init

    init(profile: HealingProfileV2 = HealingProfileV2()) {

        // -- Nasal upper tri-exponential --

        aFast = 0.45
        aMed  = 0.30
        aSlow = 0.25

        tauFast = 7.0
        tauMed  = 35.0

        var baseTauSlow: Float
        switch profile.skinThickness {
        case .thin:   baseTauSlow = 90
        case .medium: baseTauSlow = 120
        case .thick:  baseTauSlow = 180
        }

        if let age = profile.age {
            if age < 30 { baseTauSlow *= 0.90 }
            else if age > 50 { baseTauSlow *= 1.15 }
        }

        if profile.surgeryType == .revision {
            baseTauSlow *= 1.25
        }

        tauSlow = baseTauSlow

        // -- Nasal ramp-up (edema build-up from surgery, peak ≈ day 3–5 for upper) --
        nasalRampTau = 3.0

        // -- Nasal tip onset + bias --

        tipImmediateRatio = 0.20
        tipOnsetTau = 5.0
        tipBiasGain = profile.skinThickness == .thick ? 0.80 : 0.50
        tipBiasTau  = 45.0   // plateau reached by ~90 days (3× tau)

        // -- Periorbital edema (osteotomy-dependent) --

        periEdemaTpeak = 2.0
        periEdemaPower = 3.0

        switch profile.osteotomy {
        case .none:    periEdemaScale = 0.30
        case .lateral: periEdemaScale = 0.70
        case .full:    periEdemaScale = 1.00
        }

        // -- Periorbital bruise (osteotomy + bruising toggle) --

        periBruiseTpeak = 2.5
        periBruisePower = 2.2

        let baseBruiseScale: Float
        switch profile.osteotomy {
        case .none:    baseBruiseScale = 0.20
        case .lateral: baseBruiseScale = 0.60
        case .full:    baseBruiseScale = 1.00
        }
        periBruiseScale = profile.bruisingPresent ? baseBruiseScale : 0.0
        bruisingEnabled = profile.bruisingPresent

        // -- Steroids --
        // Confined to: periorbital (edema + bruise) and nasal fast component only.
        // Short decay (τ = 5 days): effect negligible by ~J7.

        steroidDecayTau = 5.0

        switch profile.steroidProtocol {
        case .none:
            steroidPeriReduction      = 0.00
            steroidNasalFastReduction = 0.00
        case .single:
            steroidPeriReduction      = 0.15
            steroidNasalFastReduction = 0.10
        case .multiDose:
            steroidPeriReduction      = 0.25
            steroidNasalFastReduction = 0.15
        }

        // -- Displacement maxima (mm) --

        maxDispUpperMM = 3.5
        maxDispTipMM   = 5.0
        maxDispPeriMM  = 2.5

        // -- Uncertainty ±30 % --

        bandLow  = 0.70
        bandHigh = 1.30
    }

    // MARK: - Nasal Ramp-Up

    /// Edema onset ramp: 0 at t=0, asymptotes to 1.
    /// Models progressive build-up of surgical edema over the first days.
    func nasalRampUp(at t: Float) -> Float {
        guard t > 0 else { return 0 }
        return 1.0 - exp(-t / nasalRampTau)
    }

    // MARK: - Nasal Upper Swelling

    /// Ramped tri-exponential decay S_upper(t) ∈ [0, 1].
    ///
    /// ```
    /// S_upper(t) = ramp(t) * [ a_fast * exp(-t/τ_fast) * steroidFastMod(t)
    ///                          + a_med  * exp(-t/τ_med)
    ///                          + a_slow * exp(-t/τ_slow) ]
    /// ```
    ///
    /// The ramp-up ensures S_upper(0) = 0 and peak occurs around day 3–5.
    /// Steroids affect only the fast component with a short-lived decay (τ_steroid = 5 days),
    /// ensuring no steroid benefit beyond ~J7.
    func nasalUpperSwelling(at t: Float) -> Float {
        guard t >= 0 else { return 0 }
        let ramp = nasalRampUp(at: t)
        let steroidFastMod = 1.0 - steroidNasalFastReduction * exp(-t / steroidDecayTau)
        let decay = aFast * exp(-t / tauFast) * steroidFastMod
                  + aMed  * exp(-t / tauMed)
                  + aSlow * exp(-t / tauSlow)
        return min(max(ramp * decay, 0), 1)
    }

    // MARK: - Tip Bias

    /// Non-decreasing ratio ≥ 1 on [0, ~90 days], then plateau.
    /// Tip retains more swelling over time relative to upper nasal.
    func tipBiasRatio(at t: Float) -> Float {
        1.0 + tipBiasGain * (1.0 - exp(-t / tipBiasTau))
    }

    // MARK: - Nasal Tip Swelling

    /// Delayed-onset tip curve with ramp-up.
    ///
    /// ```
    /// S_tip(t) = ramp(t) * [ α · base(t) + (1−α) · onset(t) · base(t) · tipBias(t) ]
    /// ```
    ///
    /// where base(t) is the unramped tri-exponential decay.
    /// The tip-specific onset and the nasal ramp combine to produce a peak around day 7–10.
    func nasalTipSwelling(at t: Float) -> Float {
        guard t >= 0 else { return 0 }
        let ramp = nasalRampUp(at: t)
        // Use unramped decay as the base envelope
        let steroidFastMod = 1.0 - steroidNasalFastReduction * exp(-t / steroidDecayTau)
        let baseDecay = aFast * exp(-t / tauFast) * steroidFastMod
                      + aMed  * exp(-t / tauMed)
                      + aSlow * exp(-t / tauSlow)
        let onset = 1.0 - exp(-t / tipOnsetTau)
        let delayed = (1.0 - tipImmediateRatio) * onset * baseDecay * tipBiasRatio(at: t)
        let total = ramp * (tipImmediateRatio * baseDecay + delayed)
        return min(max(total, 0), 1)
    }

    // MARK: - Nasal Total Displacement

    /// Aggregate nasal displacement (mm) = upper + tip contributions.
    /// Peak of this quantity must fall within [7, 14] days.
    func nasalTotalDisplacement(at t: Float) -> Float {
        nasalUpperSwelling(at: t) * maxDispUpperMM + nasalTipSwelling(at: t) * maxDispTipMM
    }

    // MARK: - Periorbital Edema

    /// Peaked power curve: peak at `tPeak`, near-zero at ≈ 4× tPeak.
    /// Steroids reduce amplitude with short decay (τ = 5 days).
    ///
    /// ```
    /// E(t) = scale · ((t / tPeak) · exp(1 − t / tPeak))^power · steroidMod(t)
    /// ```
    func periorbitalEdema(at t: Float) -> Float {
        guard t > 0 else { return 0 }
        let steroidMod = 1.0 - steroidPeriReduction * exp(-t / steroidDecayTau)
        let norm = t / periEdemaTpeak
        let base = norm * exp(1.0 - norm)
        let shaped = powf(base, periEdemaPower) * steroidMod
        return min(max(shaped * periEdemaScale, 0), 1)
    }

    // MARK: - Periorbital Bruise

    /// Peaked power curve for ecchymosis intensity.
    /// Steroids reduce amplitude (same short decay).
    func periorbitalBruiseLevel(at t: Float) -> Float {
        guard t > 0, bruisingEnabled else { return 0 }
        let steroidMod = 1.0 - steroidPeriReduction * exp(-t / steroidDecayTau)
        let norm = t / periBruiseTpeak
        let base = norm * exp(1.0 - norm)
        let shaped = powf(base, periBruisePower) * steroidMod
        return min(max(shaped * periBruiseScale, 0), 1)
    }

    // MARK: - Bruise Color

    /// Interpolated bruise RGB. Transitions red-violet → purple → green → yellow → fade.
    func bruiseColor(at t: Float) -> SIMD3<Float> {
        let colors = Self.bruiseColorsV2
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

    // MARK: - Full Evaluation

    func evaluate(at t: Float) -> HealingStateV2 {
        let upper     = nasalUpperSwelling(at: t)
        let tip       = nasalTipSwelling(at: t)
        let periEdema = periorbitalEdema(at: t)
        let periBruis = periorbitalBruiseLevel(at: t)

        return HealingStateV2(
            day: t,
            nasalUpperSwelling: upper,
            nasalTipSwelling: tip,
            periorbitalEdema: periEdema,
            nasalUpperSwellingMin:  clampUnit(upper * bandLow),
            nasalUpperSwellingMax:  clampUnit(upper * bandHigh),
            nasalTipSwellingMin:    clampUnit(tip * bandLow),
            nasalTipSwellingMax:    clampUnit(tip * bandHigh),
            periorbitalEdemaMin:    clampUnit(periEdema * bandLow),
            periorbitalEdemaMax:    clampUnit(periEdema * bandHigh),
            periorbitalBruiseLevel: periBruis,
            bruiseColor:            bruiseColor(at: t),
            nasalUpperDisplacementMM: upper * maxDispUpperMM,
            nasalTipDisplacementMM:   tip * maxDispTipMM,
            periorbitalDisplacementMM: periEdema * maxDispPeriMM
        )
    }

    // MARK: - Presets

    static let presetDays: [Float] = [0, 1, 3, 7, 14, 30, 90, 180, 365]

    func timeline() -> [HealingStateV2] {
        Self.presetDays.map { evaluate(at: $0) }
    }

    // MARK: - Helpers

    private func clampUnit(_ v: Float) -> Float {
        min(max(v, 0), 1)
    }
}
