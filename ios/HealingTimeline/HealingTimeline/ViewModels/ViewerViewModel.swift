import SwiftUI
import simd

/// Manages the 3D viewer state and healing simulation.
@MainActor
final class ViewerViewModel: ObservableObject {
    @Published var sliderDay: Double = 0
    @Published var currentState: HealingState = HealingState(
        day: 0, swellingLevel: 1, swellingMin: 0.65, swellingMax: 1,
        bruisingLevel: 0, bruiseColor: SIMD3<Float>(0.4, 0.1, 0.3),
        nasalVolumeDelta: 4
    )
    @Published var displayMesh: FaceMeshData?
    @Published var showRange = false
    @Published var showSettings = false
    @Published var showShareSheet = false

    private var baseMesh: FaceMeshData?
    private var model: HealingModel?

    var dayLabel: String {
        let day = Int(sliderDay)
        if day == 0 { return "Surgery Day" }
        if day == 1 { return "Day 1" }
        if day < 30 { return "Day \(day)" }
        if day < 365 {
            let months = day / 30
            return "\(months) month\(months > 1 ? "s" : "")"
        }
        return "12 months"
    }

    func setup(mesh: FaceMeshData, profile: HealingProfile) {
        baseMesh = mesh
        model = HealingModel(profile: profile)
        setDay(Float(sliderDay))
    }

    func setDay(_ day: Float) {
        guard let model = model, let baseMesh = baseMesh else { return }
        currentState = model.evaluate(at: day)
        displayMesh = baseMesh.displaced(by: currentState)
    }

    func exportSnapshots() {
        // Export 4 key timepoints as images
        // In a real implementation, this would render to offscreen buffers
        let exportDays: [Float] = [1, 7, 30, 365]
        for day in exportDays {
            if let model = model {
                _ = model.evaluate(at: day)
                // TODO: Render to UIImage and save to photo library
            }
        }
    }
}
