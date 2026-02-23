import Foundation
import simd

/// Output of the healing model at a single timepoint.
struct HealingState {
    let day: Float
    let swellingLevel: Float        // 0-1
    let swellingMin: Float
    let swellingMax: Float
    let bruisingLevel: Float        // 0-1
    let bruiseColor: SIMD3<Float>   // RGB 0-1
    let nasalVolumeDelta: Float     // mm
}
