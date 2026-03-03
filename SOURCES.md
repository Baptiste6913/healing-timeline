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

## V2 Multi-Compartment Model — Additional Sources

### Periorbital Edema & Bruise Timing

| Source | Data Used | License/Access |
|--------|-----------|----------------|
| Kara CO, Gokce G, "Periorbital Ecchymosis and Subconjunctival Hemorrhage Following Rhinoplasty", J Craniofac Surg 2014 | Periorbital bruise peak (J2-3), resolution timing (97% by J10) | Factual data extraction |
| Guyuron B, "Rhinoplasty", Elsevier (publicly available summary tables) | Periorbital edema peak J2, near-resolution by J8 | Fair use (factual data) |
| Rettinger G, "Risks and Complications in Rhinoplasty", GMS 2007 | Osteotomy impact on periorbital swelling severity | Open Access (CC-BY) |

### Nasal Tip Delayed Resolution

| Source | Data Used | License/Access |
|--------|-----------|----------------|
| Rohrich & Ahmad, PRS 2019 | Tip swelling persists longest, 12-18 months for thick skin | Open Access |
| Daniel RK, "Tip Refinement: A 30-Year Experience", PRS 2009 | Tip vs dorsum differential resolution rates | Factual data extraction |
| Guyuron B, "Rhinoplasty" | 2/3 resolved at 1 month, 95% at 6 months, 97.5% at 12 months (nasal aggregate) | Fair use (factual data) |

### Steroid Effects on Edema

| Source | Data Used | License/Access |
|--------|-----------|----------------|
| Youssef TA et al., "Effect of Steroids on Edema After Rhinoplasty", Ann Plast Surg 2013 | Short-term steroid reduction (~15-25%), effect fading by 2-4 weeks | Open Access |

### Skin Thickness & Healing Dynamics

| Source | Data Used | License/Access |
|--------|-----------|----------------|
| Daniel RK, "The Swollen Nose", ASJ 2016 | Thick skin delays resolution: tau_slow ratio thin:medium:thick | Factual data |
| Rohrich & Ahmad, PRS 2019 | Skin thickness categories and qualitative healing timelines | Open Access |

### V2-Specific Factual Data Points

These are **factual observations** (not copyrighted expression):

- Periorbital edema peaks at Day 2, largely resolved by Day 8
- Periorbital bruising peaks Day 2-3, 97% resolved by Day 10
- Nasal tip swelling peaks around Day 7-14 (delayed onset due to fluid redistribution)
- Nasal aggregate: 2/3 resolved at 1 month, 95% at 6 months, 97.5% at 12 months
- Tip bias (tip vs dorsum differential) increases over time: tip is last to resolve
- Osteotomy intensity correlates with periorbital swelling severity
- Steroids reduce early edema (first 2 weeks) but do not affect long-term resolution
- Revision surgery slows healing by approximately 25%

## What Is NOT Used

- No patient photos or scans
- No proprietary clinical datasets
- No paid databases
- No HIPAA/PHI data
