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

                    // Frame counter badge
                    if scanVM.framesCollected > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.metering.multispot")
                                .font(.system(size: 12))
                            Text("\(scanVM.framesCollected)f")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Face guide oval with countdown ring
                if showGuide {
                    ZStack {
                        FaceGuideOverlay(state: scanVM.trackingState)

                        // Countdown progress ring
                        if scanVM.countdownProgress > 0 {
                            Ellipse()
                                .trim(from: 0, to: CGFloat(scanVM.countdownProgress))
                                .stroke(
                                    scanVM.countdownProgress >= 1.0 ? Color.green : Color.cyan,
                                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                                )
                                .frame(width: 226, height: 306)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.1), value: scanVM.countdownProgress)
                        }
                    }
                }

                Spacer()

                // Micro-movement indicator
                if case .countdown = scanVM.scanPhase {
                    jitterIndicator
                        .padding(.bottom, 8)
                }

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
                        VStack(spacing: 2) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text("Capture")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.white)
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
                // Brief processing delay
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    await MainActor.run {
                        withAnimation {
                            appState.currentScreen = .viewer
                        }
                    }
                }
            }
        }
    }

    // MARK: - Jitter Indicator

    private var jitterIndicator: some View {
        let rmsMM = scanVM.lastFrameRMS * 1000
        let barWidth = min(1.0, CGFloat(rmsMM / 2.0)) // scale: 0mm = empty, 2mm = full
        let barColor: Color = rmsMM < 0.3 ? .green : (rmsMM < 0.8 ? .yellow : .red)

        return HStack(spacing: 8) {
            Text("Jitter")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 6)
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * barWidth, height: 6)
                        .animation(.easeOut(duration: 0.15), value: barWidth)
                }
            }
            .frame(width: 80, height: 6)

            Text(String(format: "%.2fmm", rmsMM))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(barColor)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
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
