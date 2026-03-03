# Model Card — Healing Timeline Simulation V1

## Overview
Parametric model predicting **illustrative** post-rhinoplasty appearance over time.
**NOT a medical device. NOT diagnostic. NOT patient-specific.**

## Model Type
Deterministic parametric curves. No machine learning.

## Outputs
For each timepoint t (days post-op):
- `swelling_level(t)` ∈ [0, 1] — normalized edema intensity
- `bruising_level(t)` ∈ [0, 1] — normalized ecchymosis intensity
- `bruise_hue(t)` — color phase (purple → green → yellow)
- `nasal_volume_delta(t)` — extra volume as fraction of surgical change

---

## Equations

### Swelling (Bi-Exponential Decay)

```
S(t) = A₁ · exp(-t / τ₁) + A₂ · exp(-t / τ₂)
```

Where:
- A₁ = 0.6 (fast component amplitude)
- A₂ = 0.4 (slow component amplitude)
- τ₁ = 7 days (fast decay half-life ~5 days)
- τ₂ = 90 days (slow decay half-life ~62 days)
- S(0) = 1.0 (peak swelling at Day 0-1)

Calibration points (from public clinical data):
| Day | S(t) median | Range (min–max) |
|-----|-------------|-----------------|
| 0   | 1.00 | 0.8–1.0 |
| 3   | 0.85 | 0.7–0.95 |
| 7   | 0.60 | 0.4–0.75 |
| 14  | 0.40 | 0.25–0.55 |
| 30  | 0.22 | 0.15–0.35 |
| 90  | 0.08 | 0.03–0.15 |
| 180 | 0.03 | 0.01–0.06 |
| 365 | 0.01 | 0.00–0.03 |

### Bruising (Log-Normal Rise-Fall)

```
B(t) = B_max · (t / t_peak) · exp(1 - t / t_peak)    for t > 0
B(0) = 0
```

Where:
- B_max = 1.0 (peak bruising intensity)
- t_peak = 2.5 days (peak bruising time)
- Resolution: B(t) < 0.05 by Day 12–14

Color transition:
| Phase | Days | RGB Base |
|-------|------|----------|
| Purple/Red | 0–3 | (0.4, 0.1, 0.3) |
| Blue-Purple | 3–5 | (0.3, 0.1, 0.4) |
| Green | 5–8 | (0.2, 0.4, 0.2) |
| Yellow-Green | 8–11 | (0.6, 0.6, 0.1) |
| Yellow-Fade | 11–14 | (0.7, 0.7, 0.3) → transparent |

### Nasal Volume Delta

```
V(t) = S(t) · V_max · zone_weight
```

Where V_max depends on intensity slider:
- Low: 2mm displacement
- Medium: 4mm displacement (default)
- High: 6mm displacement

Zone weights:
- Nasal tip: 1.0
- Dorsum: 0.7
- Alar: 0.5
- Periorbital: 0.4

---

## Personalization Sliders

| Slider | Effect | Range |
|--------|--------|-------|
| Skin Thickness | Modifies τ₂ (slow decay): thin=60d, thick=150d | Thin / Medium / Thick |
| Initial Intensity | Scales S(0) and B_max | Low (0.6) / Medium (1.0) / High (1.3) |
| Bruising Presence | Toggles bruise overlay | Yes / No |
| Age (optional) | Slight τ₂ modifier: younger=0.9x, older=1.1x | 18–70 |

---

## Limitations

1. **Not patient-specific** — uses population-level averages
2. **No anatomical adaptation** — same zone masks for all face shapes
3. **Color approximation** — bruise colors are simplified gradients
4. **No complication modeling** — assumes normal uncomplicated recovery
5. **Illustrative only** — should not inform clinical decisions

## Validation

- Monotonicity checks: swelling strictly decreasing after t=0
- Bruising resolution: approaches zero by Day 14
- Visual plausibility review against published recovery photo timelines

---
---

# Model Card — Healing Timeline Simulation V2

> Feature-flagged (`FeatureFlags.healingModelV2Enabled`, OFF by default).

## Overview

Multi-compartment parametric model predicting **illustrative** post-rhinoplasty
appearance over time. Four anatomical compartments with independent curves
calibrated to published clinical milestones.

**NOT a medical device. NOT diagnostic. NOT patient-specific.**

## Model Type

Deterministic parametric curves. No machine learning. On-device evaluation.

## Compartments

| Compartment | Anatomical Area | Weight |
|-------------|----------------|--------|
| `nasal_upper` | Dorsum + sidewall | 2/3 of nasal envelope |
| `nasal_tip` | Tip + supra-tip | 1/3, slowest resolution |
| `periorbital_edema` | Periorbital soft tissue | Fast cycle |
| `periorbital_bruise` | Ecchymosis | Fast cycle, color evolution |

## T0 Definition

T0 = moment of surgical completion (end of procedure, not incision).
All timepoints are in days post-T0.

## Equations

### Time Origin / PRS Baseline Reconciliation

T0 = surgical completion (end of procedure). All timepoints are in days post-T0.

PRS literature baselines (1–2 weeks post-op) are used as calibration anchors. The
model is fitted so that S_agg(30) ≈ 0.33, representing 2/3 resolved at 1 month.

The ramp-up from 0 to peak (days 0–7) models the progressive onset of surgical
edema that is underway before the earliest clinical baseline measurement at 1–2
weeks. This reconciles the mathematical S(0) = 0 with the clinical reality that
swelling is already present (and growing) from the moment of surgery.

```
ramp(t) = 1 - exp(-t / tau_ramp)     tau_ramp = 3.0 days
```

At t = 0: ramp = 0 (no edema yet).
At t = 3: ramp ≈ 0.63 (edema building).
At t = 7: ramp ≈ 0.90 (near-peak for upper nasal).
At t ≫ 7: ramp → 1.0 (ramp transparent, pure decay governs).

### Nasal Upper (Ramped Tri-Exponential Decay)

```
S_upper(t) = ramp(t) * [ a_fast * exp(-t/tau_fast) * steroidFastMod(t)
                          + a_med  * exp(-t/tau_med)
                          + a_slow * exp(-t/tau_slow) ]
```

Where:
- a_fast = 0.45, a_med = 0.30, a_slow = 0.25 (sum = 1.0)
- tau_fast = 7 days, tau_med = 35 days
- tau_slow depends on skin thickness: thin=90, medium=120, thick=180 days
- steroidFastMod(t) = 1 - steroidNasalFastReduction * exp(-t / steroidDecayTau)
- steroidDecayTau = 5 days (effect negligible by ~J7)
- Steroids affect fast component only — no modification of medium/slow
- Age modifier: <30 years = 0.9x tau_slow, >50 years = 1.15x tau_slow
- Revision modifier: 1.25x tau_slow

### Nasal Tip (Delayed Onset + Bias + Ramp-Up)

```
S_tip(t) = ramp(t) * [ alpha * base(t) + (1-alpha) * onset(t) * base(t) * tipBias(t) ]

base(t) = unramped tri-exponential decay (same as upper without ramp)
onset(t) = 1 - exp(-t / tau_onset)
tipBias(t) = 1 + gain * (1 - exp(-t / tau_bias))
```

Where:
- alpha = 0.20 (immediate response fraction)
- tau_onset = 5 days
- gain = 0.50 (default) or 0.80 (thick skin)
- tau_bias = 45 days (plateau reached by ~90 days, 3x tau)
- tipBias is monotonically non-decreasing on [7, 90], stable (plateau) after
- Peak tip displacement occurs around Day 10

### Nasal Total Displacement

```
D_total(t) = S_upper(t) * max_upper_mm + S_tip(t) * max_tip_mm
```

Hard constraint: argmax(D_total) ∈ [7, 14] days. Validated peak at day 8.5.

### Periorbital Edema (Peaked Power Curve)

```
E(t) = scale * ((t/t_peak) * exp(1 - t/t_peak))^power * steroidMod(t)
```

Where:
- t_peak = 2.0 days (peak at J2)
- power = 3.0 (steep decay)
- scale depends on osteotomy: none=0.30, lateral=0.70, full=1.00
- steroidMod(t) = 1 - steroidPeriReduction * exp(-t / steroidDecayTau)

### Periorbital Bruise (Peaked Power Curve)

```
B(t) = scale * ((t/t_peak) * exp(1 - t/t_peak))^power * steroidMod(t)
```

Where:
- t_peak = 2.5 days
- power = 2.2
- scale depends on osteotomy: none=0.20, lateral=0.60, full=1.00
- steroidMod same as periorbital edema

### Bruise Color (RGB Keyframes)

| Day | RGB | Phase |
|-----|-----|-------|
| 0 | (0.45, 0.08, 0.30) | Red-violet |
| 1 | (0.35, 0.08, 0.40) | Deep purple |
| 3 | (0.28, 0.12, 0.42) | Blue-purple |
| 5 | (0.18, 0.38, 0.18) | Green |
| 7 | (0.45, 0.55, 0.10) | Yellow-green |
| 10 | (0.65, 0.65, 0.30) | Yellow-fade |
| 14 | (0.80, 0.78, 0.55) | Near-skin |

### Displacement

Per-compartment displacement in mm:
- Nasal upper max: 3.5 mm
- Nasal tip max: 5.0 mm
- Periorbital max: 2.5 mm

Zone-weight-based blending for smooth transitions between compartments.

### Uncertainty Bands

All compartments: +/- 30% (bandLow=0.70, bandHigh=1.30).

## Hard Constraints (from medical literature)

| Constraint | Target | Validated |
|-----------|--------|-----------|
| Periorbital edema peak at J2 | E(1) < E(2) > E(3) | YES |
| Periorbital edema resolved at J8 | E(8) < 5% | YES |
| Periorbital bruise resolved J10 | B(10) < 3% | YES |
| Nasal 2/3 resolved at 1 month | S_agg(30) in [0.28, 0.38] | YES (0.349) |
| Nasal 95% resolved at 6 months | S_agg(180) in [0.02, 0.08] | YES (0.065) |
| Nasal 97.5% resolved at 12 months | S_agg(365) in [0.005, 0.045] | YES (0.014) |
| Nasal total displacement peak 7-14 | argmax(D_total) in [7, 14] | YES (day 8.5) |
| Tip volume peak 7-14 days | peak day in [7, 14] | YES (day 10) |
| Nasal total monotone after peak | non-increasing after argmax | YES |
| Steroids no nasal benefit beyond J7 | diff(J7) < 0.02, diff(J30) < 0.001 | YES |
| Tip bias non-decreasing [7, 90] | monotone on [7, 90] | YES |
| Tip bias stable after 90 | drift < 5% | YES (4.7%) |
| Bruise monotone after J3 | non-increasing | YES |
| No negatives/NaN/Inf | all values >= 0, finite | YES |

## Personalization Parameters (V2)

| Parameter | Effect | Values |
|-----------|--------|--------|
| Skin Thickness | tau_slow + tipBias gain | Thin / Medium / Thick |
| Surgery Type | tau_slow modifier | Primary (1.0x) / Revision (1.25x) |
| Osteotomy | Periorbital scale | None / Lateral / Full |
| Steroid Protocol | Periorbital + nasal fast only (tau=5d) | None / Single / Multi-dose |
| Bruising Present | Toggle bruise | Yes / No |
| Age | tau_slow modifier | <30: 0.9x, >50: 1.15x |

## Limitations

1. **Not patient-specific** — uses population-level averages
2. **No anatomical adaptation** — same zone masks for all face shapes
3. **Color approximation** — bruise colors are simplified gradients
4. **No complication modeling** — assumes normal uncomplicated recovery
5. **Illustrative only** — should not inform clinical decisions
6. **Compartment boundaries** — zone weights are approximate, not anatomically segmented
7. **Steroid effect** — confined to periorbital + nasal fast component; short decay (tau=5d), not pharmacokinetically modeled

## Validation

- 16 hard constraint checks (all passing) — see `scripts/fit_healing_v2.py`
- 40+ unit tests covering milestones, monotonicity, bounds, steroids, ramp-up, and cross-profile comparisons
- Skin thickness variants validated: thin, medium, thick all within acceptable ranges
- Python reference curves exported to `model/output/healing_curves_v2.json`
