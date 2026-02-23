# Data Sources

All data used to calibrate the healing model comes from **publicly available** clinical literature
and open-access resources. No patient data is used. No diagnostic claims are made.

## Clinical Literature (open-access / fair-use factual data)

| Source | Data Used | License/Access |
|--------|-----------|----------------|
| Rohrich & Ahmad, "Is Dorsal Reduction with a 'Component' Approach Better?", PRS 2019 (open-access) | Swelling resolution timeline, typical recovery milestones | Open Access (CC-BY-NC) |
| Guyuron B., "Rhinoplasty", Elsevier — publicly available summary tables | Edema percentage at standard timepoints | Fair use (factual data only) |
| Daniel RK, "The Swollen Nose After Rhinoplasty", Aesthetic Surgery Journal 2016 (open figures) | Swelling decay curve shape (bi-exponential pattern) | Factual data extraction |
| Rettinger G, "Risks and Complications in Rhinoplasty", GMS Current Topics Otorhinolaryngol 2007 | Bruising timeline (onset, peak, resolution) | Open Access (CC-BY) |
| Gorkem Atsal et al., "Recovery After Rhinoplasty", Facial Plast Surg 2020 | Day-by-day bruising color transitions | Open Access |
| RealSelf.com community reports (aggregated public testimonials) | Qualitative recovery timelines for calibration range | Publicly posted |

## Factual Data Points Extracted

These are **factual observations** (not copyrighted expression):

- Swelling peaks at Day 1–3, resolves ~60% by 2 weeks, ~80% by 1 month, ~95% by 6 months, ~99% by 12 months
- Bruising appears Day 0–1, peaks Day 2–3, transitions purple→green→yellow, resolves by Day 10–14
- Nasal tip swelling persists longest (up to 12–18 months for thick skin)
- Periorbital bruising common, resolves faster than nasal swelling

## 3D / Geometry Resources

| Resource | Usage | License |
|----------|-------|---------|
| ARKit Face Mesh (Apple) | Runtime face geometry capture | Apple Developer License |
| Generated sample mesh (this repo) | Testing fixture | MIT (this project) |

## What Is NOT Used

- No patient photos or scans
- No proprietary clinical datasets
- No paid databases
- No HIPAA/PHI data
