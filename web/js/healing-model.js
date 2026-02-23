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
    const BRUISE_COLORS = [
        [0,  [0.40, 0.10, 0.30]],  // red-purple
        [3,  [0.30, 0.10, 0.40]],  // blue-purple
        [5,  [0.20, 0.40, 0.20]],  // green
        [8,  [0.60, 0.60, 0.10]],  // yellow-green
        [11, [0.70, 0.70, 0.30]],  // yellow-fade
        [14, [0.80, 0.80, 0.50]],  // near-skin
    ];

    class HealingModel {
        constructor(profile = {}) {
            this.skinThickness = profile.skinThickness || "medium";
            this.initialIntensity = profile.initialIntensity || "medium";
            this.bruisingPresent = profile.bruisingPresent !== false;
            this.age = profile.age || null;

            // Compute derived params
            this.A1 = 0.6;
            this.A2 = 0.4;
            this.tau1 = 7.0;

            let tau2 = SKIN_TAU2[this.skinThickness] || 90;
            if (this.age !== null) {
                if (this.age < 30) tau2 *= 0.9;
                else if (this.age > 50) tau2 *= 1.1;
            }
            this.tau2 = tau2;

            this.intensityScale = INTENSITY_SCALE[this.initialIntensity] || 1.0;
            this.maxDisplacementMM = V_MAX[this.initialIntensity] || 4.0;
            this.tPeakBruise = 2.5;
        }

        /** Bi-exponential swelling decay S(t) in [0, 1]. */
        swelling(t) {
            const s = this.A1 * Math.exp(-t / this.tau1) + this.A2 * Math.exp(-t / this.tau2);
            return Math.max(0, Math.min(1, s * this.intensityScale));
        }

        /** Swelling range: {min, median, max}. */
        swellingRange(t) {
            const med = this.swelling(t);
            return {
                min: Math.max(0, Math.min(1, med * 0.65)),
                median: med,
                max: Math.max(0, Math.min(1, med * 1.25)),
            };
        }

        /** Log-normal-like bruising curve B(t) in [0, 1]. */
        bruising(t) {
            if (!this.bruisingPresent || t <= 0) return 0;
            const tp = this.tPeakBruise;
            const b = (t / tp) * Math.exp(1.0 - t / tp);
            return Math.max(0, Math.min(1, b * this.intensityScale));
        }

        /** Interpolated bruise color RGB at time t. */
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

        /** Nasal volume delta in mm. */
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
