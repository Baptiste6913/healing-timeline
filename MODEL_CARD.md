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
