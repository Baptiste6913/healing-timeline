# Healing Timeline Simulation

**Rhinovate** — Post-rhinoplasty recovery visualization prototype.

> **DISCLAIMER:** This is an illustrative simulation only. It does NOT provide medical advice,
> diagnosis, or treatment. Individual recovery varies. Always consult a qualified surgeon.

## What It Does

1. **3D Face Scan** — Captures a face mesh using iPhone's TrueDepth camera (ARKit). Falls back to a procedural sample mesh for demo.
2. **Healing Simulation** — Applies a parametric model (bi-exponential swelling decay + log-normal bruising) to deform the mesh over time.
3. **Timeline Viewer** — Interactive 3D viewer with a slider to scrub from Day 0 to 12 months post-op.

## Repository Structure

```
healing-timeline-simulation/
├── ios/                          # iOS app (SwiftUI + RealityKit + ARKit)
│   └── HealingTimeline/
│       ├── HealingTimeline/
│       │   ├── App/              # App entry + state
│       │   ├── Views/            # SwiftUI screens
│       │   ├── ViewModels/       # Scan + Viewer logic
│       │   ├── Models/           # Data models + healing math
│       │   ├── Services/         # AR, mesh rendering, processing
│       │   └── Shaders/          # Metal shaders (bruise overlay)
│       └── HealingTimeline.xcodeproj/
├── data/
│   ├── scripts/                  # Python data ingestion
│   │   ├── healing_data.py       # Clinical data normalization
│   │   └── requirements.txt
│   └── output/                   # Generated JSON/CSV (gitignored)
├── model/
│   ├── src/
│   │   ├── healing_model.py      # Parametric model implementation
│   │   ├── fit_curves.py         # Curve fitting validation
│   │   └── plot_curves.py        # Visualization
│   ├── tests/
│   │   └── test_healing_model.py # Unit tests
│   └── output/                   # Generated timelines (gitignored)
├── fixtures/
│   ├── generate_sample_mesh.py   # Procedural head mesh generator
│   ├── sample_face.obj           # Generated sample (after running)
│   └── sample_zones.json         # Zone assignments
├── docs/
├── DECISIONS.md                  # Technical choices
├── DEPENDENCIES.md               # All deps with justification
├── MODEL_CARD.md                 # Model equations + limits
├── SOURCES.md                    # Data sources + licenses
└── README.md                     # This file
```

## Quick Start

### Python Data Pipeline

```bash
# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate        # macOS/Linux
# .venv\Scripts\activate         # Windows

# Install deps
pip install -r data/scripts/requirements.txt

# Run data ingestion
python data/scripts/healing_data.py

# Run model + generate timeline
python model/src/healing_model.py

# Fit curves to clinical data
python model/src/fit_curves.py

# Generate plots
python model/src/plot_curves.py

# Run tests
python model/tests/test_healing_model.py

# Generate sample mesh
python fixtures/generate_sample_mesh.py
```

### iOS App

```bash
# Requirements: Xcode 15+, macOS 14+, iOS 17+ device
open ios/HealingTimeline/HealingTimeline.xcodeproj

# In Xcode:
# 1. Select your development team (Signing & Capabilities)
# 2. Select your iPhone as build target
# 3. Cmd+R to build and run
#
# Note: Face tracking requires a physical iPhone with TrueDepth camera.
# The simulator will use the sample mesh (demo mode).
```

### Run Tests

```bash
# Python
python model/tests/test_healing_model.py

# iOS (from Xcode)
# Cmd+U to run HealingTimelineTests
```

## How the Model Works

See [MODEL_CARD.md](MODEL_CARD.md) for full equations.

**Swelling:** `S(t) = 0.6·exp(-t/7) + 0.4·exp(-t/τ₂)` where τ₂ varies by skin thickness (60–150 days).

**Bruising:** `B(t) = (t/2.5)·exp(1 - t/2.5)` — peaks at Day 2.5, resolves by Day 14.

**Mesh deformation:** Vertex displacement along normals, weighted by anatomical zone (tip=1.0, dorsum=0.7, alar=0.5, periorbital=0.4).

**Bruise color:** Interpolated keyframes: red-purple → blue-purple → green → yellow → fade.

## Privacy

- All processing is on-device
- No network calls
- No data collection
- Face scan data stays in app sandbox

## Limitations

- Population-average model, not patient-specific
- Simplified anatomical zones
- No complication modeling
- Illustrative only

## License

Proprietary — Rhinovate Inc.
