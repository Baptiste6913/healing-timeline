import SwiftUI
import ARKit
import RealityKit

/// UIViewRepresentable wrapper for ARKit face tracking session.
struct ARScanViewRepresentable: UIViewRepresentable {
    @ObservedObject var viewModel: ScanViewModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false

        // Configure face tracking if available
        if ARFaceTrackingConfiguration.isSupported {
            let config = ARFaceTrackingConfiguration()
            config.maximumNumberOfTrackedFaces = 1
            config.isLightEstimationEnabled = true
            arView.session.run(config)
            arView.session.delegate = context.coordinator
        } else {
            // Fallback: use standard camera with Vision face detection
            let config = ARWorldTrackingConfiguration()
            config.isLightEstimationEnabled = true
            arView.session.run(config)
            arView.session.delegate = context.coordinator
            context.coordinator.useFallbackMode = true
        }

        context.coordinator.viewModel = viewModel
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> ARScanCoordinator {
        ARScanCoordinator()
    }
}

// MARK: - Coordinator

final class ARScanCoordinator: NSObject, ARSessionDelegate {
    weak var viewModel: ScanViewModel?
    var useFallbackMode = false

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let viewModel = viewModel else { return }

        if let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first {
            // Grab the current frame for depth data + camera transform
            let currentFrame = session.currentFrame
            Task { @MainActor in
                viewModel.updateTracking(
                    anchor: faceAnchor,
                    frame: currentFrame
                )
            }
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        if anchors.contains(where: { $0 is ARFaceAnchor }) {
            Task { @MainActor in
                viewModel?.lostTracking()
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            viewModel?.lostTracking()
        }
    }
}
