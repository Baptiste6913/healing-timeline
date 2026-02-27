/**
 * healing-model.js — Parametric healing model (JavaScript port).
 * Exact port of model/src/healing_model.py.
 * See MODEL_CARD.md for equations.
 *
 * DISCLAIMER: Illustrative simulation only. Not medical advice.
 */

const HealingModelJS = (() => {

    // ── Profile defaults ──────────────────────────────────────────────
    const SKIN_TAU2 = { thin: 60, medium: 90, thick: 150 };
    const INTENSITY_SCALE = { low: 0.6, medium: 1.0, high: 1.3 };
    const V_MAX = { low: 2.0, medium: 4.0, high: 6.0 };

    // ── Bruise color keyframes: [day, [r, g, b]] ──────────────────────
    // Follows hemoglobin degradation pathway:
    // Hb → metHb (red→purple) → biliverdin (green) → bilirubin (yellow)
    const BRUISE_COLORS = [
        [0,  [0.50, 0.15, 0.20]],  // dark red (fresh hemorrhage)
        [2,  [0.40, 0.10, 0.35]],  // red-purple (early deoxygenation)
        [4,  [0.30, 0.12, 0.42]],  // deep purple (methemoglobin)
        [7,  [0.25, 0.35, 0.35]],  // blue-green (biliverdin)
        [10, [0.50, 0.55, 0.15]],  // yellow-green (bilirubin forming)
        [14, [0.65, 0.60, 0.30]],  // yellow (bilirubin dominant)
        [21, [0.80, 0.75, 0.55]],  // near-skin (resolving)
    ];

    class HealingModel {
        constructor(profile = {}) {
            this.skinThickness = profile.skinThickness || "medium";
            this.initialIntensity = profile.initialIntensity || "medium";
            this.bruisingPresent = profile.bruisingPresent !== false;
            this.age = profile.age || null;

            // ── Bi-exponential decay parameters ──
            // A1: fast component weight (soft tissue edema, resolves in weeks)
            // A2: slow component weight (deep tissue/fibrosis, resolves in months)
            this.A1 = 0.6;
            this.A2 = 0.4;
            this.tau1 = 7.0;  // fast time constant (days)

            let tau2 = SKIN_TAU2[this.skinThickness] || 90;
            if (this.age !== null) {
                if (this.age < 30) tau2 *= 0.9;
                else if (this.age > 50) tau2 *= 1.1;
            }
            this.tau2 = tau2;  // slow time constant (days)

            this.intensityScale = INTENSITY_SCALE[this.initialIntensity] || 1.0;
            this.maxDisplacementMM = V_MAX[this.initialIntensity] || 4.0;
            this.tPeakBruise = 2.5;

            // ── Onset time constant ──
            // Edema develops over 48-72h post-surgery (inflammatory cascade)
            // tOnset controls how fast swelling builds up
            this.tOnset = 0.8; // days — reaches ~63% at 0.8d, ~95% at 2.4d

            // ── Pre-compute peak normalization ──
            // The combined onset * decay function peaks around day 2-3.
            // We normalize so the peak = 1.0 before intensity scaling.
            let peakVal = 0;
            for (let t = 0.5; t <= 5; t += 0.1) {
                const onset = 1 - Math.exp(-t / this.tOnset);
                const decay = this.A1 * Math.exp(-t / this.tau1)
                            + this.A2 * Math.exp(-t / this.tau2);
                peakVal = Math.max(peakVal, onset * decay);
            }
            this._peakNorm = peakVal || 1;
        }

        /**
         * Swelling curve S(t) in [0, 1].
         *
         * Clinically accurate timeline:
         *   Day 0 (surgery): ~0%  — edema hasn't developed yet
         *   Day 1:           ~65% — rapid onset (inflammatory cascade)
         *   Day 2-3:         ~100% — peak edema
         *   Day 7:           ~60% — rapid initial resolution
         *   Day 14:          ~40% — cast removal, still visible swelling
         *   Month 1:         ~25% — shape becoming clearer
         *   Month 3:         ~12% — mostly tip/supratip remaining
         *   Month 6:         ~5%  — subtle tip refinement ongoing
         *   Month 12:        ~1%  — final result
         *
         * Model: onset(t) × bi-exponential_decay(t), normalized to peak = 1.0
         *   onset(t)   = 1 − exp(−t / τ_onset)  [inflammatory edema development]
         *   decay(t)   = A₁·exp(−t/τ₁) + A₂·exp(−t/τ₂)  [resolution]
         */
        swelling(t) {
            if (t <= 0) return 0;

            // Onset: inflammatory edema accumulation (peaks ~48-72h)
            const onset = 1 - Math.exp(-t / this.tOnset);

            // Bi-exponential resolution
            const decay = this.A1 * Math.exp(-t / this.tau1)
                        + this.A2 * Math.exp(-t / this.tau2);

            // Normalized so peak = 1.0
            const s = (onset * decay) / this._peakNorm;

            return Math.max(0, Math.min(1, s * this.intensityScale));
        }

        /** Swelling range: {min, median, max} for confidence band display. */
        swellingRange(t) {
            const med = this.swelling(t);
            return {
                min: Math.max(0, Math.min(1, med * 0.65)),
                median: med,
                max: Math.max(0, Math.min(1, med * 1.25)),
            };
        }

        /**
         * Periorbital ecchymosis (bruising) curve B(t) in [0, 1].
         *
         * Timeline:
         *   Day 0:   0%   — no bruising yet
         *   Day 1:   ~73% — appearing rapidly
         *   Day 2.5: 100% — peak
         *   Day 5:   ~74% — still significant
         *   Day 7:   ~46% — visibly improving
         *   Day 14:  ~6%  — nearly resolved
         *   Day 21:  ~0%  — resolved
         */
        bruising(t) {
            if (!this.bruisingPresent || t <= 0) return 0;
            const tp = this.tPeakBruise;
            const b = (t / tp) * Math.exp(1.0 - t / tp);
            return Math.max(0, Math.min(1, b * this.intensityScale));
        }

        /** Interpolated bruise color RGB at time t (hemoglobin degradation). */
        bruiseColor(t) {
            if (t <= 0) return [...BRUISE_COLORS[0][1]];
            const colors = BRUISE_COLORS;
            for (let i = 0; i < colors.length - 1; i++) {
                const [t0, c0] = colors[i];
                const [t1, c1] = colors[i + 1];
                if (t >= t0 && t <= t1) {
                    const frac = (t - t0) / (t1 - t0);
                    return [
                        c0[0] + frac * (c1[0] - c0[0]),
                        c0[1] + frac * (c1[1] - c0[1]),
                        c0[2] + frac * (c1[2] - c0[2]),
                    ];
                }
            }
            return [...colors[colors.length - 1][1]];
        }

        /** Nasal volume delta in mm at time t. */
        nasalVolumeDelta(t) {
            return this.swelling(t) * this.maxDisplacementMM;
        }

        /** Full evaluation at a single timepoint. */
        evaluate(t) {
            const range = this.swellingRange(t);
            return {
                day: t,
                swellingLevel: range.median,
                swellingMin: range.min,
                swellingMax: range.max,
                bruisingLevel: this.bruising(t),
                bruiseColor: this.bruiseColor(t),
                nasalVolumeDelta: this.nasalVolumeDelta(t),
            };
        }
    }

    // ── Preset days ───────────────────────────────────────────────────
    const PRESET_DAYS = [
        { day: 0,   label: "Surgery" },
        { day: 1,   label: "Day 1" },
        { day: 3,   label: "Day 3" },
        { day: 7,   label: "1 Week" },
        { day: 14,  label: "2 Weeks" },
        { day: 30,  label: "1 Month" },
        { day: 90,  label: "3 Months" },
        { day: 180, label: "6 Months" },
        { day: 365, label: "12 Months" },
    ];

    return { HealingModel, PRESET_DAYS, BRUISE_COLORS };
})();

if (typeof window !== 'undefined') {
    window.HealingModelJS = HealingModelJS;
}
