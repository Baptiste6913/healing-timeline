"""
healing_model.py — Parametric healing forecast model for post-rhinoplasty simulation.

See MODEL_CARD.md for equations, parameters, and limitations.
This is an ILLUSTRATIVE model. Not medical advice.
"""

import numpy as np
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class PatientProfile:
    """Non-medical personalization parameters."""
    skin_thickness: str = "medium"       # "thin", "medium", "thick"
    initial_intensity: str = "medium"    # "low", "medium", "high"
    bruising_present: bool = True
    age: Optional[int] = None            # 18-70, optional

    def intensity_scale(self) -> float:
        return {"low": 0.6, "medium": 1.0, "high": 1.3}[self.initial_intensity]

    def slow_decay_tau(self) -> float:
        """τ₂ in days, modified by skin thickness and age."""
        base = {"thin": 60.0, "medium": 90.0, "thick": 150.0}[self.skin_thickness]
        if self.age is not None:
            if self.age < 30:
                base *= 0.9
            elif self.age > 50:
                base *= 1.1
        return base


@dataclass
class HealingState:
    """Model output at a single timepoint."""
    day: float
    swelling_level: float       # 0-1
    swelling_min: float         # lower bound
    swelling_max: float         # upper bound
    bruising_level: float       # 0-1
    bruise_color_rgb: tuple     # (r, g, b) in 0-1
    nasal_volume_delta: float   # mm displacement at tip


class HealingModel:
    """Parametric bi-exponential + log-normal healing model."""

    # -- Swelling parameters --
    A1 = 0.6       # fast component amplitude
    A2 = 0.4       # slow component amplitude
    TAU1 = 7.0     # fast decay constant (days)
    # TAU2 set by patient profile

    # -- Bruising parameters --
    T_PEAK_BRUISE = 2.5    # days to peak bruising

    # -- Volume parameters --
    V_MAX = {"low": 2.0, "medium": 4.0, "high": 6.0}  # mm

    # -- Bruise color keyframes (day -> RGB) --
    BRUISE_COLORS = [
        (0.0,  (0.40, 0.10, 0.30)),   # red-purple
        (3.0,  (0.30, 0.10, 0.40)),   # blue-purple
        (5.0,  (0.20, 0.40, 0.20)),   # green
        (8.0,  (0.60, 0.60, 0.10)),   # yellow-green
        (11.0, (0.70, 0.70, 0.30)),   # yellow-fade
        (14.0, (0.80, 0.80, 0.50)),   # near-skin
    ]

    # -- Swelling variance envelope --
    VARIANCE_FACTOR_MIN = 0.65
    VARIANCE_FACTOR_MAX = 1.25

    def __init__(self, profile: Optional[PatientProfile] = None):
        self.profile = profile or PatientProfile()

    def swelling(self, t: float) -> float:
        """Bi-exponential swelling decay S(t) ∈ [0, 1]."""
        tau2 = self.profile.slow_decay_tau()
        scale = self.profile.intensity_scale()
        s = self.A1 * np.exp(-t / self.TAU1) + self.A2 * np.exp(-t / tau2)
        return float(np.clip(s * scale, 0.0, 1.0))

    def swelling_range(self, t: float) -> tuple:
        """Return (min, median, max) swelling at time t."""
        median = self.swelling(t)
        s_min = float(np.clip(median * self.VARIANCE_FACTOR_MIN, 0.0, 1.0))
        s_max = float(np.clip(median * self.VARIANCE_FACTOR_MAX, 0.0, 1.0))
        return (s_min, median, s_max)

    def bruising(self, t: float) -> float:
        """Log-normal-like bruising curve B(t) ∈ [0, 1]."""
        if not self.profile.bruising_present:
            return 0.0
        if t <= 0:
            return 0.0
        tp = self.T_PEAK_BRUISE
        scale = self.profile.intensity_scale()
        b = (t / tp) * np.exp(1.0 - t / tp)
        return float(np.clip(b * scale, 0.0, 1.0))

    def bruise_color(self, t: float) -> tuple:
        """Interpolate bruise color RGB at time t."""
        if t <= 0:
            return self.BRUISE_COLORS[0][1]

        colors = self.BRUISE_COLORS
        # Find bracketing keyframes
        for i in range(len(colors) - 1):
            t0, c0 = colors[i]
            t1, c1 = colors[i + 1]
            if t0 <= t <= t1:
                frac = (t - t0) / (t1 - t0)
                r = c0[0] + frac * (c1[0] - c0[0])
                g = c0[1] + frac * (c1[1] - c0[1])
                b = c0[2] + frac * (c1[2] - c0[2])
                return (r, g, b)

        # Beyond last keyframe
        return colors[-1][1]

    def nasal_volume_delta(self, t: float) -> float:
        """Extra nasal displacement in mm at time t."""
        v_max = self.V_MAX[self.profile.initial_intensity]
        return self.swelling(t) * v_max

    def evaluate(self, t: float) -> HealingState:
        """Full evaluation at a single timepoint."""
        s_min, s_med, s_max = self.swelling_range(t)
        return HealingState(
            day=t,
            swelling_level=s_med,
            swelling_min=s_min,
            swelling_max=s_max,
            bruising_level=self.bruising(t),
            bruise_color_rgb=self.bruise_color(t),
            nasal_volume_delta=self.nasal_volume_delta(t),
        )

    def timeline(self, days: Optional[list] = None) -> list:
        """Evaluate at standard timepoints or custom list."""
        if days is None:
            days = [0, 1, 3, 7, 14, 30, 90, 180, 365]
        return [self.evaluate(d) for d in days]

    def continuous_timeline(self, max_day: int = 365, step: float = 1.0) -> list:
        """Evaluate at every step for smooth curves."""
        days = np.arange(0, max_day + step, step)
        return [self.evaluate(float(d)) for d in days]

    def to_json_array(self, states: list) -> list:
        """Serialize states for iOS consumption."""
        return [
            {
                "day": s.day,
                "swelling": round(s.swelling_level, 4),
                "swelling_min": round(s.swelling_min, 4),
                "swelling_max": round(s.swelling_max, 4),
                "bruising": round(s.bruising_level, 4),
                "bruise_r": round(s.bruise_color_rgb[0], 3),
                "bruise_g": round(s.bruise_color_rgb[1], 3),
                "bruise_b": round(s.bruise_color_rgb[2], 3),
                "volume_delta_mm": round(s.nasal_volume_delta, 2),
            }
            for s in states
        ]


# -- CLI ----------------------------------------------------------------------

def main():
    import json
    from pathlib import Path

    model = HealingModel(PatientProfile(
        skin_thickness="medium",
        initial_intensity="medium",
        bruising_present=True,
    ))

    # Standard timepoints
    states = model.timeline()
    data = model.to_json_array(states)

    output_dir = Path(__file__).parent.parent / "output"
    output_dir.mkdir(parents=True, exist_ok=True)

    # Standard timepoints
    with open(output_dir / "healing_timeline.json", "w") as f:
        json.dump({"disclaimer": "Illustrative only. Not medical advice.", "timeline": data}, f, indent=2)
    print(f"[OK] Standard timeline -> {output_dir / 'healing_timeline.json'}")

    # Continuous curve (for plotting / iOS smooth slider)
    continuous = model.continuous_timeline(365, step=1.0)
    cont_data = model.to_json_array(continuous)
    with open(output_dir / "healing_continuous.json", "w") as f:
        json.dump({"disclaimer": "Illustrative only. Not medical advice.", "timeline": cont_data}, f, indent=2)
    print(f"[OK] Continuous curve -> {output_dir / 'healing_continuous.json'}")

    # Print summary
    print("\n-- Healing Timeline (median) --")
    print(f"{'Day':>5} {'Swell':>7} {'Bruise':>7} {'Vol(mm)':>8} {'Bruise Color':>15}")
    for s in states:
        cr, cg, cb = s.bruise_color_rgb
        print(f"{s.day:5.0f} {s.swelling_level:7.3f} {s.bruising_level:7.3f} {s.nasal_volume_delta:8.2f} "
              f"({cr:.2f},{cg:.2f},{cb:.2f})")


if __name__ == "__main__":
    main()
