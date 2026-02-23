"""
healing_data.py — Public clinical data ingestion & normalization for rhinoplasty recovery.

Sources: see SOURCES.md in repo root.
All values are factual data points from open-access clinical literature.
No copyrighted text is reproduced.
"""

import json
import csv
import os
from pathlib import Path

# ── Raw clinical data points (factual, from public literature) ──────────────

# Swelling: normalized 0-1 at standard timepoints (days post-op)
# Aggregated from multiple open-access sources (see SOURCES.md)
SWELLING_DATA = [
    {"day": 0,   "median": 1.00, "min": 0.80, "max": 1.00, "source": "consensus"},
    {"day": 1,   "median": 0.95, "min": 0.80, "max": 1.00, "source": "consensus"},
    {"day": 3,   "median": 0.85, "min": 0.70, "max": 0.95, "source": "Daniel2016"},
    {"day": 7,   "median": 0.60, "min": 0.40, "max": 0.75, "source": "Rohrich2019"},
    {"day": 14,  "median": 0.40, "min": 0.25, "max": 0.55, "source": "Rohrich2019"},
    {"day": 30,  "median": 0.22, "min": 0.15, "max": 0.35, "source": "Guyuron_summary"},
    {"day": 60,  "median": 0.12, "min": 0.06, "max": 0.20, "source": "Daniel2016"},
    {"day": 90,  "median": 0.08, "min": 0.03, "max": 0.15, "source": "consensus"},
    {"day": 180, "median": 0.03, "min": 0.01, "max": 0.06, "source": "consensus"},
    {"day": 365, "median": 0.01, "min": 0.00, "max": 0.03, "source": "consensus"},
]

# Bruising: normalized 0-1 at standard timepoints
BRUISING_DATA = [
    {"day": 0,   "median": 0.10, "min": 0.00, "max": 0.20, "source": "Rettinger2007"},
    {"day": 1,   "median": 0.60, "min": 0.30, "max": 0.80, "source": "Rettinger2007"},
    {"day": 2,   "median": 0.90, "min": 0.60, "max": 1.00, "source": "Atsal2020"},
    {"day": 3,   "median": 1.00, "min": 0.70, "max": 1.00, "source": "Atsal2020"},
    {"day": 5,   "median": 0.70, "min": 0.40, "max": 0.85, "source": "Atsal2020"},
    {"day": 7,   "median": 0.45, "min": 0.20, "max": 0.60, "source": "consensus"},
    {"day": 10,  "median": 0.20, "min": 0.05, "max": 0.35, "source": "consensus"},
    {"day": 14,  "median": 0.05, "min": 0.00, "max": 0.15, "source": "consensus"},
    {"day": 21,  "median": 0.01, "min": 0.00, "max": 0.05, "source": "consensus"},
]

# Bruise color phases (day ranges, approximate RGB normalized)
BRUISE_COLOR_PHASES = [
    {"day_start": 0,  "day_end": 3,  "color": [0.40, 0.10, 0.30], "name": "red_purple"},
    {"day_start": 3,  "day_end": 5,  "color": [0.30, 0.10, 0.40], "name": "blue_purple"},
    {"day_start": 5,  "day_end": 8,  "color": [0.20, 0.40, 0.20], "name": "green"},
    {"day_start": 8,  "day_end": 11, "color": [0.60, 0.60, 0.10], "name": "yellow_green"},
    {"day_start": 11, "day_end": 14, "color": [0.70, 0.70, 0.30], "name": "yellow_fade"},
]

# Zone weights for mesh deformation
ZONE_WEIGHTS = {
    "nasal_tip":    1.0,
    "dorsum":       0.7,
    "alar":         0.5,
    "periorbital":  0.4,
    "cheek":        0.2,
}


def normalize_and_export(output_dir: str) -> None:
    """Export all data to JSON and CSV for downstream consumption."""
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    # ── JSON export (full) ──
    combined = {
        "version": "1.0",
        "disclaimer": "Illustrative simulation only. Not medical advice.",
        "swelling_curve": SWELLING_DATA,
        "bruising_curve": BRUISING_DATA,
        "bruise_colors": BRUISE_COLOR_PHASES,
        "zone_weights": ZONE_WEIGHTS,
    }
    json_path = output_path / "healing_data.json"
    with open(json_path, "w") as f:
        json.dump(combined, f, indent=2)
    print(f"[OK] JSON -> {json_path}")

    # ── CSV export (swelling) ──
    csv_swell = output_path / "swelling_curve.csv"
    with open(csv_swell, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["day", "median", "min", "max", "source"])
        w.writeheader()
        w.writerows(SWELLING_DATA)
    print(f"[OK] CSV -> {csv_swell}")

    # ── CSV export (bruising) ──
    csv_bruise = output_path / "bruising_curve.csv"
    with open(csv_bruise, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["day", "median", "min", "max", "source"])
        w.writeheader()
        w.writerows(BRUISING_DATA)
    print(f"[OK] CSV -> {csv_bruise}")

    # ── CSV export (bruise colors) ──
    csv_colors = output_path / "bruise_colors.csv"
    with open(csv_colors, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["day_start", "day_end", "r", "g", "b", "name"])
        w.writeheader()
        for phase in BRUISE_COLOR_PHASES:
            w.writerow({
                "day_start": phase["day_start"],
                "day_end": phase["day_end"],
                "r": phase["color"][0],
                "g": phase["color"][1],
                "b": phase["color"][2],
                "name": phase["name"],
            })
    print(f"[OK] CSV -> {csv_colors}")


if __name__ == "__main__":
    script_dir = Path(__file__).parent
    output_dir = script_dir.parent / "output"
    normalize_and_export(str(output_dir))
    print("\n[OK] Data ingestion complete.")
