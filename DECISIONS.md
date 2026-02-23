# Technical Decisions

## D1 — iOS Minimum Target: iOS 17
ARKit face tracking + RealityKit require iOS 17+. Covers ~85% active devices.

## D2 — Primary Scan: ARFaceTracking (TrueDepth)
Provides a 1220-vertex face mesh in real-time. Available on iPhone X+ (front camera).
Fallback for devices without TrueDepth: Vision framework face landmarks (2D) projected onto a generic head mesh.

## D3 — No Server / No Cloud
All processing on-device. No data leaves the phone. Privacy by architecture.

## D4 — Parametric Healing Model (not ML)
Bi-exponential decay for swelling, log-normal curve for bruising. Fully explicable.
ML "light" upgrade path documented but not implemented in V1.

## D5 — Mesh Deformation via Vertex Displacement
Anatomical zone masks (nose dorsum, tip, periorbital) with smoothstep falloff.
Displacement magnitude driven by the parametric model output at each timepoint.

## D6 — Bruising as Procedural Texture Overlay
Metal shader composites bruise color (purple→green→yellow) over the base texture.
Intensity and hue controlled by time-dependent parameters from the model.

## D7 — Sample Mesh for Testing
Procedurally generated ellipsoid+nose geometry. No real patient data.

## D8 — USDZ for Export
Apple-native format, viewable in Files/AR Quick Look. OBJ as secondary.

## D9 — Python Data Pipeline Uses Only numpy + scipy
Minimal dependencies. No ML frameworks needed for V1.

## D10 — No Medical Claims
Disclaimer displayed at app launch + in settings. README header.
