# Dependencies

## iOS App

| Dependency | Version | Why | License |
|------------|---------|-----|---------|
| SwiftUI | iOS 17+ (built-in) | Declarative UI, native Apple | Apple SDK |
| RealityKit | iOS 17+ (built-in) | 3D rendering, mesh display | Apple SDK |
| ARKit | iOS 17+ (built-in) | Face tracking, LiDAR mesh, camera | Apple SDK |
| Vision | iOS 17+ (built-in) | Face landmark detection (fallback) | Apple SDK |
| Metal | iOS 17+ (built-in) | Custom shaders for bruise overlay | Apple SDK |
| ModelIO | iOS 17+ (built-in) | Mesh I/O (OBJ/USDZ) | Apple SDK |

**No third-party iOS dependencies.** Everything uses Apple frameworks.

## Python Data Pipeline

| Dependency | Version | Why | License |
|------------|---------|-----|---------|
| numpy | >=1.24 | Array operations, curve math | BSD-3-Clause |
| scipy | >=1.11 | Curve fitting (optimize.curve_fit) | BSD-3-Clause |
| matplotlib | >=3.7 | Visualization of healing curves (dev only) | PSF-based |

## Dev Tools

| Tool | Why |
|------|-----|
| Xcode 15+ | iOS build |
| Python 3.10+ | Data scripts |
| Git | Version control |
