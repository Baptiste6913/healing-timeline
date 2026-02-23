"""
plot_curves.py — Visualize healing model curves.
Generates PNG plots for documentation and validation.
"""

import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path
from healing_model import HealingModel, PatientProfile


def plot_swelling_curves(output_dir: Path):
    """Plot swelling curves for different skin types."""
    fig, ax = plt.subplots(figsize=(10, 6))
    days = np.arange(0, 366, 1)

    for thickness, color, ls in [("thin", "#2196F3", "-"), ("medium", "#4CAF50", "-"), ("thick", "#FF9800", "-")]:
        model = HealingModel(PatientProfile(skin_thickness=thickness))
        swell = [model.swelling(d) for d in days]
        ax.plot(days, swell, color=color, linestyle=ls, linewidth=2, label=f"Skin: {thickness}")

    # Add range envelope for medium
    model_med = HealingModel(PatientProfile(skin_thickness="medium"))
    s_min = [model_med.swelling_range(d)[0] for d in days]
    s_max = [model_med.swelling_range(d)[2] for d in days]
    ax.fill_between(days, s_min, s_max, alpha=0.15, color="#4CAF50", label="Range (medium)")

    # Clinical data points
    clin_days = [0, 3, 7, 14, 30, 90, 180, 365]
    clin_vals = [1.0, 0.85, 0.60, 0.40, 0.22, 0.08, 0.03, 0.01]
    ax.scatter(clin_days, clin_vals, color="red", zorder=5, s=60, label="Clinical data points")

    ax.set_xlabel("Days Post-Op", fontsize=12)
    ax.set_ylabel("Swelling Level (0–1)", fontsize=12)
    ax.set_title("Post-Rhinoplasty Swelling Model", fontsize=14)
    ax.legend()
    ax.set_xlim(0, 365)
    ax.set_ylim(0, 1.05)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(output_dir / "swelling_curves.png", dpi=150)
    print(f"[OK] Plot -> {output_dir / 'swelling_curves.png'}")
    plt.close()


def plot_bruising_curve(output_dir: Path):
    """Plot bruising intensity + color phases."""
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8), gridspec_kw={'height_ratios': [3, 1]})

    model = HealingModel()
    days = np.arange(0, 22, 0.1)
    bruise = [model.bruising(d) for d in days]
    colors = [model.bruise_color(d) for d in days]

    ax1.plot(days, bruise, color="#9C27B0", linewidth=2, label="Bruising intensity")
    ax1.fill_between(days, 0, bruise, alpha=0.2, color="#9C27B0")
    ax1.set_ylabel("Bruising Level (0–1)", fontsize=12)
    ax1.set_title("Post-Rhinoplasty Bruising Model", fontsize=14)
    ax1.legend()
    ax1.set_xlim(0, 21)
    ax1.set_ylim(0, 1.1)
    ax1.grid(True, alpha=0.3)

    # Color bar
    for i, d in enumerate(days):
        ax2.axvspan(d, d + 0.1, color=colors[i], alpha=0.8)
    ax2.set_xlabel("Days Post-Op", fontsize=12)
    ax2.set_ylabel("Color", fontsize=12)
    ax2.set_xlim(0, 21)
    ax2.set_yticks([])

    fig.tight_layout()
    fig.savefig(output_dir / "bruising_curve.png", dpi=150)
    print(f"[OK] Plot -> {output_dir / 'bruising_curve.png'}")
    plt.close()


def plot_combined_timeline(output_dir: Path):
    """Combined view with key timepoints."""
    fig, ax = plt.subplots(figsize=(12, 6))
    model = HealingModel()
    days = np.arange(0, 366, 1)

    swell = [model.swelling(d) for d in days]
    bruise_full = np.arange(0, 22, 0.1)
    bruise_vals = [model.bruising(d) for d in bruise_full]

    ax.plot(days, swell, color="#2196F3", linewidth=2, label="Swelling")
    ax.plot(bruise_full, bruise_vals, color="#9C27B0", linewidth=2, label="Bruising")

    # Key timepoints
    presets = [1, 3, 7, 14, 30, 90, 180, 365]
    for d in presets:
        ax.axvline(d, color="gray", alpha=0.2, linestyle="--")
        s = model.swelling(d)
        ax.annotate(f"D{d}", (d, s), textcoords="offset points", xytext=(5, 10), fontsize=8, color="gray")

    ax.set_xlabel("Days Post-Op", fontsize=12)
    ax.set_ylabel("Level (0–1)", fontsize=12)
    ax.set_title("Healing Timeline — Combined View", fontsize=14)
    ax.legend()
    ax.set_xlim(0, 365)
    ax.set_ylim(0, 1.1)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(output_dir / "combined_timeline.png", dpi=150)
    print(f"[OK] Plot -> {output_dir / 'combined_timeline.png'}")
    plt.close()


if __name__ == "__main__":
    output_dir = Path(__file__).parent.parent / "output"
    output_dir.mkdir(parents=True, exist_ok=True)
    plot_swelling_curves(output_dir)
    plot_bruising_curve(output_dir)
    plot_combined_timeline(output_dir)
    print("\n[OK] All plots generated.")
