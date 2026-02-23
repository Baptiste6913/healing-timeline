import SwiftUI
import Combine

/// Global navigation and data state.
enum AppScreen {
    case splash
    case scan
    case processing
    case viewer
}

@MainActor
final class AppState: ObservableObject {
    @Published var currentScreen: AppScreen = .splash
    @Published var capturedMesh: FaceMeshData?
    @Published var healingProfile = HealingProfile()
    @Published var currentDay: Float = 0
    @Published var showDisclaimer = true

    func reset() {
        currentScreen = .splash
        capturedMesh = nil
        healingProfile = HealingProfile()
        currentDay = 0
    }
}
