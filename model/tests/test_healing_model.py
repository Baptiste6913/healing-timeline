"""
test_healing_model.py — Unit tests for the parametric healing model.
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

import numpy as np
from healing_model import HealingModel, PatientProfile, HealingState


def test_swelling_peak():
    """Swelling should be at or near 1.0 at t=0."""
    model = HealingModel()
    s = model.swelling(0)
    assert 0.95 <= s <= 1.0, f"Swelling at t=0 should be ~1.0, got {s}"


def test_swelling_monotone_decrease():
    """Swelling must be monotonically decreasing after t=0."""
    model = HealingModel()
    prev = model.swelling(0)
    for d in range(1, 366):
        curr = model.swelling(d)
        assert curr <= prev + 1e-6, f"Swelling increased at day {d}: {prev} -> {curr}"
        prev = curr


def test_swelling_near_zero_at_365():
    """Swelling should be near zero at 1 year."""
    model = HealingModel()
    s = model.swelling(365)
    assert s < 0.05, f"Swelling at day 365 should be < 0.05, got {s}"


def test_swelling_range_ordered():
    """min <= median <= max at all timepoints."""
    model = HealingModel()
    for d in [0, 7, 30, 90, 365]:
        s_min, s_med, s_max = model.swelling_range(d)
        assert s_min <= s_med <= s_max, f"Range violation at day {d}: {s_min}, {s_med}, {s_max}"


def test_bruising_zero_at_t0():
    """Bruising should be 0 or near 0 at t=0."""
    model = HealingModel()
    b = model.bruising(0)
    assert b == 0.0, f"Bruising at t=0 should be 0, got {b}"


def test_bruising_peak_around_day2_3():
    """Bruising should peak near day 2-3."""
    model = HealingModel()
    values = [(d, model.bruising(d)) for d in np.arange(0, 7, 0.5)]
    peak_day, peak_val = max(values, key=lambda x: x[1])
    assert 1.5 <= peak_day <= 4.0, f"Bruise peak at day {peak_day}, expected 1.5-4.0"


def test_bruising_resolved_by_day14():
    """Bruising should be < 0.1 by day 14."""
    model = HealingModel()
    b = model.bruising(14)
    assert b < 0.1, f"Bruising at day 14 should be < 0.1, got {b}"


def test_bruising_off():
    """When bruising_present=False, bruising should be 0."""
    model = HealingModel(PatientProfile(bruising_present=False))
    for d in [0, 3, 7, 14]:
        assert model.bruising(d) == 0.0, f"Bruising should be 0 at day {d} when disabled"


def test_bruise_color_valid_rgb():
    """Bruise colors should be valid RGB in [0, 1]."""
    model = HealingModel()
    for d in range(0, 15):
        r, g, b = model.bruise_color(d)
        assert 0 <= r <= 1 and 0 <= g <= 1 and 0 <= b <= 1, \
            f"Invalid color at day {d}: ({r}, {g}, {b})"


def test_volume_delta_positive():
    """Volume delta should be positive when swelling > 0."""
    model = HealingModel()
    for d in [0, 1, 7, 30]:
        v = model.nasal_volume_delta(d)
        assert v >= 0, f"Volume delta negative at day {d}: {v}"


def test_volume_delta_decreases():
    """Volume delta should decrease over time."""
    model = HealingModel()
    prev = model.nasal_volume_delta(0)
    for d in range(1, 366):
        curr = model.nasal_volume_delta(d)
        assert curr <= prev + 1e-6, f"Volume increased at day {d}"
        prev = curr


def test_skin_thickness_effect():
    """Thick skin should have higher swelling at day 90 than thin skin."""
    model_thin = HealingModel(PatientProfile(skin_thickness="thin"))
    model_thick = HealingModel(PatientProfile(skin_thickness="thick"))
    s_thin = model_thin.swelling(90)
    s_thick = model_thick.swelling(90)
    assert s_thick > s_thin, f"Thick skin ({s_thick}) should have more swelling than thin ({s_thin}) at D90"


def test_intensity_scale():
    """High intensity should produce more swelling than low."""
    model_low = HealingModel(PatientProfile(initial_intensity="low"))
    model_high = HealingModel(PatientProfile(initial_intensity="high"))
    assert model_high.swelling(7) > model_low.swelling(7)


def test_evaluate_returns_healing_state():
    """evaluate() should return a HealingState with all fields."""
    model = HealingModel()
    state = model.evaluate(7)
    assert isinstance(state, HealingState)
    assert state.day == 7
    assert 0 <= state.swelling_level <= 1
    assert 0 <= state.bruising_level <= 1


def test_timeline_length():
    """timeline() should return correct number of states."""
    model = HealingModel()
    states = model.timeline()
    assert len(states) == 9  # default timepoints


def test_json_serialization():
    """to_json_array should produce valid dicts."""
    model = HealingModel()
    states = model.timeline()
    data = model.to_json_array(states)
    assert len(data) == 9
    assert "day" in data[0]
    assert "swelling" in data[0]
    assert "bruise_r" in data[0]


# ── Run all tests ────────────────────────────────────────────────────────────

if __name__ == "__main__":
    tests = [v for k, v in globals().items() if k.startswith("test_")]
    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            print(f"  [PASS] {test.__name__}")
            passed += 1
        except AssertionError as e:
            print(f"  [FAIL] {test.__name__}: {e}")
            failed += 1
        except Exception as e:
            print(f"  [FAIL] {test.__name__}: EXCEPTION: {e}")
            failed += 1

    print(f"\n{'='*40}")
    print(f"Results: {passed} passed, {failed} failed, {passed+failed} total")
    if failed > 0:
        sys.exit(1)
