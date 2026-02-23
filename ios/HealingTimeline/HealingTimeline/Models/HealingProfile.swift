import Foundation

/// Non-medical personalization parameters for the healing simulation.
struct HealingProfile: Codable, Equatable {
    enum SkinThickness: String, Codable, CaseIterable {
        case thin, medium, thick

        var slowDecayTau: Float {
            switch self {
            case .thin: return 60
            case .medium: return 90
            case .thick: return 150
            }
        }
    }

    enum Intensity: String, Codable, CaseIterable {
        case low, medium, high

        var scale: Float {
            switch self {
            case .low: return 0.6
            case .medium: return 1.0
            case .high: return 1.3
            }
        }

        var maxDisplacementMM: Float {
            switch self {
            case .low: return 2.0
            case .medium: return 4.0
            case .high: return 6.0
            }
        }
    }

    var skinThickness: SkinThickness = .medium
    var initialIntensity: Intensity = .medium
    var bruisingPresent: Bool = true
    var age: Int? = nil
}
