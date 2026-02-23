"""
fit_curves.py -- Fit parametric curves to clinical data points.

Validates the bi-exponential and log-normal models against extracted data.
Outputs fitted parameters and residuals.
"""

import numpy as np
from scipy.optimize import curve_fit
import json
from pathlib import Path


def bi_exponential(t, a1, tau1, a2, tau2):
    """Bi-exponential decay: S(t) = a1*exp(-t/tau1) + a2*exp(-t/tau2)"""
    return a1 * np.exp(-t / tau1) + a2 * np.exp(-t / tau2)


def bruise_curve(t, b_max, t_peak):
    """Modified gamma-like bruise curve: B(t) = b_max * (t/t_peak) * exp(1 - t/t_peak)"""
    result = np.zeros_like(t, dtype=float)
    mask = t > 0
    result[mask] = b_max * (t[mask] / t_peak) * np.exp(1.0 - t[mask] / t_peak)
    return result


def load_clinical_data(data_dir: str):
    """Load the normalized clinical data."""
    data_path = Path(data_dir) / "healing_data.json"
    with open(data_path) as f:
        data = json.load(f)
    return data


def fit_swelling(data: dict) -> dict:
    """Fit bi-exponential to swelling data."""
    points = data["swelling_curve"]
    t = np.array([p["day"] for p in points], dtype=float)
    y = np.array([p["median"] for p in points], dtype=float)

    # Initial guesses
    p0 = [0.6, 7.0, 0.4, 90.0]
    bounds = ([0, 1, 0, 20], [1, 30, 1, 300])

    popt, pcov = curve_fit(bi_exponential, t, y, p0=p0, bounds=bounds)
    a1, tau1, a2, tau2 = popt

    # Residuals
    y_pred = bi_exponential(t, *popt)
    residuals = y - y_pred
    rmse = float(np.sqrt(np.mean(residuals**2)))

    result = {
        "model": "bi_exponential",
        "params": {"A1": round(a1, 4), "tau1": round(tau1, 2), "A2": round(a2, 4), "tau2": round(tau2, 2)},
        "rmse": round(rmse, 6),
        "residuals": [round(r, 4) for r in residuals],
    }
    print(f"[Swelling Fit] A1={a1:.4f}, tau1={tau1:.2f}d, A2={a2:.4f}, tau2={tau2:.2f}d -- RMSE={rmse:.6f}")
    return result


def fit_bruising(data: dict) -> dict:
    """Fit log-normal-like curve to bruising data."""
    points = data["bruising_curve"]
    t = np.array([p["day"] for p in points], dtype=float)
    y = np.array([p["median"] for p in points], dtype=float)

    p0 = [1.0, 2.5]
    bounds = ([0.5, 1.0], [1.5, 5.0])

    popt, pcov = curve_fit(bruise_curve, t, y, p0=p0, bounds=bounds)
    b_max, t_peak = popt

    y_pred = bruise_curve(t, *popt)
    residuals = y - y_pred
    rmse = float(np.sqrt(np.mean(residuals**2)))

    result = {
        "model": "gamma_like",
        "params": {"B_max": round(b_max, 4), "t_peak": round(t_peak, 2)},
        "rmse": round(rmse, 6),
        "residuals": [round(r, 4) for r in residuals],
    }
    print(f"[Bruising Fit] B_max={b_max:.4f}, t_peak={t_peak:.2f}d -- RMSE={rmse:.6f}")
    return result


def main():
    data_dir = Path(__file__).parent.parent.parent / "data" / "output"
    if not (data_dir / "healing_data.json").exists():
        print("Run healing_data.py first to generate data.")
        return

    data = load_clinical_data(str(data_dir))

    swell_fit = fit_swelling(data)
    bruise_fit = fit_bruising(data)

    output_dir = Path(__file__).parent.parent / "output"
    output_dir.mkdir(parents=True, exist_ok=True)

    with open(output_dir / "curve_fits.json", "w") as f:
        json.dump({"swelling": swell_fit, "bruising": bruise_fit}, f, indent=2)
    print(f"\n[OK] Fit results -> {output_dir / 'curve_fits.json'}")


if __name__ == "__main__":
    main()
