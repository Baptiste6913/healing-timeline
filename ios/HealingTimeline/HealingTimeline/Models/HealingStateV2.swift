import Foundation
import simd

/// Multi-compartment healing state at a single timepoint.
///
/// Compartments:
/// - `nasal_upper` — dorsum + sidewall (≈ 2/3 of nasal envelope)
/// - `nasal_tip` — tip + supra-tip (≈ 1/3, slowest to resolve)
/// - `periorbital_edema` — periorbital soft-tissue edema (fast cycle)
/// - `periorbital_bruise` — ecchymosis (fast cycle, color evolution)
///
/// See MODEL_CARD.md §V2 for equations and calibration.
struct HealingStateV2 {

    let day: Float

    // -- Per-compartment swelling (normalized 0-1) -------------------------

    let nasalUpperSwelling: Float
    let nasalTipSwelling: Float
    let periorbitalEdema: Float

    // -- Uncertainty bands -------------------------------------------------

    let nasalUpperSwellingMin: Float
    let nasalUpperSwellingMax: Float
    let nasalTipSwellingMin: Float
    let nasalTipSwellingMax: Float
    let periorbitalEdemaMin: Float
    let periorbitalEdemaMax: Float

    // -- Bruising ----------------------------------------------------------

    let periorbitalBruiseLevel: Float       // 0-1
    let bruiseColor: SIMD3<Float>           // RGB 0-1

    // -- Per-compartment displacement (mm) ---------------------------------

    let nasalUpperDisplacementMM: Float
    let nasalTipDisplacementMM: Float
    let periorbitalDisplacementMM: Float

    // MARK: - Aggregates (backward-compatible helpers)

    /// Weighted-average nasal swelling: 2/3 upper + 1/3 tip.
    var nasalSwellingAggregate: Float {
        nasalUpperSwelling * (2.0 / 3.0) + nasalTipSwelling * (1.0 / 3.0)
    }

    var nasalSwellingAggregateMin: Float {
        nasalUpperSwellingMin * (2.0 / 3.0) + nasalTipSwellingMin * (1.0 / 3.0)
    }

    var nasalSwellingAggregateMax: Float {
        nasalUpperSwellingMax * (2.0 / 3.0) + nasalTipSwellingMax * (1.0 / 3.0)
    }

    /// Peak nasal displacement across compartments.
    var nasalVolumeDelta: Float {
        max(nasalUpperDisplacementMM, nasalTipDisplacementMM)
    }

    // MARK: - V1 Conversion

    /// Convert to v1 HealingState for backward-compatible rendering path.
    func toV1() -> HealingState {
        HealingState(
            day: day,
            swellingLevel: nasalSwellingAggregate,
            swellingMin: nasalSwellingAggregateMin,
            swellingMax: nasalSwellingAggregateMax,
            bruisingLevel: periorbitalBruiseLevel,
            bruiseColor: bruiseColor,
            nasalVolumeDelta: nasalVolumeDelta
        )
    }
}
