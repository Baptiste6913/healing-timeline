import SwiftUI
import ARKit

struct ScanView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var scanVM = ScanViewModel()
    @State private var showGuide = true

    var body: some View {
        ZStack {
            // AR Camera view
            ARScanViewRepresentable(viewModel: scanVM)
                .ignoresSafeArea()

            // Overlay UI
            VStack {
                // Top bar
                HStack {
                    Button {
                        withAnimation { appState.currentScreen = .splash }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Face guide oval
                if showGuide {
                    FaceGuideOverlay(state: scanVM.trackingState)
                }

                Spacer()

                // Status text
                Text(scanVM.instructionText)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .padding(.bottom, 16)

                // Capture button
                Button {
                    scanVM.capture()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                        Circle()
                            .fill(scanVM.canCapture ? Color.blue : Color.gray)
                            .frame(width: 64, height: 64)
                        Text("Capture\nNow")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    }
                }
                .disabled(!scanVM.canCapture)
                .padding(.bottom, 32)
            }
        }
        .onChange(of: scanVM.capturedMesh) { _, mesh in
            if let mesh {
                appState.capturedMesh = mesh
                withAnimation {
                    appState.currentScreen = .processing
                }
                // Simulate processing
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    await MainActor.run {
                        withAnimation {
                            appState.currentScreen = .viewer
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Face Guide Oval

struct FaceGuideOverlay: View {
    let state: ScanTrackingState

    var borderColor: Color {
        switch state {
        case .notTracking: return .white.opacity(0.5)
        case .tracking: return .yellow
        case .ready: return .green
        }
    }

    var body: some View {
        Ellipse()
            .stroke(borderColor, style: StrokeStyle(lineWidth: 3, dash: [10, 5]))
            .frame(width: 220, height: 300)
            .animation(.easeInOut(duration: 0.3), value: state)
    }
}

// MARK: - Tracking State

enum ScanTrackingState {
    case notTracking
    case tracking
    case ready
}
