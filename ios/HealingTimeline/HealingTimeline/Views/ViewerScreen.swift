import SwiftUI

struct ViewerScreen: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewerVM = ViewerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button {
                    withAnimation { appState.currentScreen = .splash }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("New Scan")
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.cyan)
                }

                Spacer()

                // Scan quality badge
                scanQualityBadge

                // Render mode badge (surgeon-grade v1)
                renderModeBadge

                // Texture mode badge
                textureModeBadge

                // Model version badge
                if viewerVM.isV2Active {
                    Text("V2")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.mint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.mint.opacity(0.15))
                        .cornerRadius(4)
                }

                Menu {
                    Button("Settings") { viewerVM.showSettings = true }
                    Button("Export Images") { viewerVM.exportSnapshots() }
                    Button("Share") { viewerVM.showShareSheet = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Scan mode banner (DEMO / quality warnings)
            scanModeBanner

            // Day label
            HStack {
                Text(viewerVM.dayLabel)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                // Swelling indicator
                if let sv2 = viewerVM.currentStateV2 {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 8) {
                            swellingChip("Tip", value: sv2.nasalTipSwelling)
                            swellingChip("Dorsum", value: sv2.nasalUpperSwelling)
                        }
                        if sv2.periorbitalEdema > 0.01 {
                            swellingChip("Peri", value: sv2.periorbitalEdema)
                        }
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Swelling")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                        Text("\(Int(viewerVM.currentState.swellingLevel * 100))%")
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundColor(swellingColor)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)

            // 3D Viewer — use render mesh when surgeon-grade available
            MeshViewerRepresentable(
                meshData: viewerVM.displayMesh,
                renderMesh: viewerVM.displayRenderMesh,
                textureAtlas: appState.capturedMesh?.textureAtlas,
                bruiseLevel: viewerVM.currentState.bruisingLevel,
                bruiseColor: viewerVM.currentState.bruiseColor
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cornerRadius(16)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Bruise indicator (if present)
            if viewerVM.currentState.bruisingLevel > 0.01 {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(
                            red: Double(viewerVM.currentState.bruiseColor.x),
                            green: Double(viewerVM.currentState.bruiseColor.y),
                            blue: Double(viewerVM.currentState.bruiseColor.z)
                        ))
                        .frame(width: 14, height: 14)
                    Text("Bruising: \(Int(viewerVM.currentState.bruisingLevel * 100))%")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 4)
            }

            // Timeline controls
            TimelineControlView(viewModel: viewerVM)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .background(Color.black)
        .onAppear {
            if let mesh = appState.capturedMesh {
                viewerVM.setup(mesh: mesh, profile: appState.healingProfile)
            }
        }
        .sheet(isPresented: $viewerVM.showSettings) {
            SettingsView(profile: $appState.healingProfile) {
                viewerVM.setup(mesh: appState.capturedMesh!, profile: appState.healingProfile)
            }
        }
    }

    // MARK: - Scan Quality Badge

    @ViewBuilder
    private var scanQualityBadge: some View {
        let mesh = appState.capturedMesh
        let mode = mesh?.scanMode ?? .coarseStable
        let grade = mesh?.qualityMetrics?.grade

        HStack(spacing: 4) {
            Image(systemName: badgeIcon(mode: mode, grade: grade))
                .font(.system(size: 10))
            Text(badgeLabel(mode: mode, grade: grade))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundColor(badgeForeground(mode: mode, grade: grade))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badgeBackground(mode: mode, grade: grade))
        .cornerRadius(6)
    }

    private func badgeIcon(mode: ScanMode, grade: ScanGrade?) -> String {
        switch mode {
        case .demo:           return "cube.transparent"
        case .depthCorrected: return "camera.metering.spot"
        case .surgeonGrade:   return "star.fill"
        case .coarseStable:
            switch grade {
            case .excellent: return "checkmark.seal.fill"
            case .good:      return "checkmark.seal"
            case .acceptable: return "exclamationmark.triangle"
            case .poor:      return "xmark.octagon"
            default:         return "waveform"
            }
        }
    }

    private func badgeLabel(mode: ScanMode, grade: ScanGrade?) -> String {
        switch mode {
        case .demo:           return "DEMO"
        case .depthCorrected: return "DEPTH"
        case .surgeonGrade:   return "3D HD"
        case .coarseStable:   return grade?.label ?? "SCAN"
        }
    }

    private func badgeForeground(mode: ScanMode, grade: ScanGrade?) -> Color {
        switch mode {
        case .demo: return .yellow
        case .depthCorrected: return .cyan
        case .surgeonGrade: return .purple
        case .coarseStable:
            switch grade {
            case .excellent: return .green
            case .good:      return .green
            case .acceptable: return .orange
            case .poor:      return .red
            default:         return .white
            }
        }
    }

    private func badgeBackground(mode: ScanMode, grade: ScanGrade?) -> Color {
        badgeForeground(mode: mode, grade: grade).opacity(0.15)
    }

    // MARK: - Mode Banner

    @ViewBuilder
    private var scanModeBanner: some View {
        let mesh = appState.capturedMesh

        if mesh?.scanMode == .demo {
            bannerView(
                icon: "exclamationmark.triangle.fill",
                text: "DEMO MODE — Sample mesh (not a real scan)",
                color: .yellow
            )
        } else if let metrics = mesh?.qualityMetrics, metrics.grade == .poor {
            bannerView(
                icon: "exclamationmark.triangle.fill",
                text: "LOW QUALITY — High jitter (\(String(format: "%.1f", metrics.meanFrameRMS * 1000))mm) or movement detected",
                color: .orange
            )
        } else if mesh?.scanMode == .surgeonGrade, !viewerVM.isSurgeonGrade {
            // Surgeon-grade scan failed quality gate → canonical fallback
            bannerView(
                icon: "exclamationmark.triangle.fill",
                text: "QUALITY GATE FAILED — \(viewerVM.surgeonGradeFailReason ?? "Using canonical mesh")",
                color: .orange
            )
        } else if mesh?.scanMode == .surgeonGrade {
            bannerView(
                icon: "star.fill",
                text: "SURGEON-GRADE 3D — Dense ROI + texture baking",
                color: .purple
            )
        } else if mesh?.scanMode == .depthCorrected {
            bannerView(
                icon: "camera.metering.spot",
                text: "DEPTH-CORRECTED — Enhanced accuracy via depth map",
                color: .cyan
            )
        }
    }

    private func bannerView(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.15))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Render Mode Badge

    @ViewBuilder
    private var renderModeBadge: some View {
        if viewerVM.isSurgeonGrade {
            HStack(spacing: 3) {
                Image(systemName: "cube.fill")
                    .font(.system(size: 9))
                Text("RENDER")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.15))
            .cornerRadius(4)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 9))
                Text("CANONICAL")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.gray)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(4)
        }
    }

    // MARK: - Texture Mode Badge

    @ViewBuilder
    private var textureModeBadge: some View {
        if appState.capturedMesh?.textureAtlas != nil {
            HStack(spacing: 3) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 9))
                Text("TEXTURED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.15))
            .cornerRadius(4)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 9))
                Text("FLAT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.gray)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(4)
        }
    }

    // MARK: - Swelling Color

    private var swellingColor: Color {
        let level = viewerVM.currentState.swellingLevel
        if level > 0.6 { return .red }
        if level > 0.3 { return .orange }
        if level > 0.1 { return .yellow }
        return .green
    }

    // MARK: - V2 Compartment Chip

    private func swellingChip(_ label: String, value: Float) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.gray)
            Text("\(Int(value * 100))%")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(chipColor(value))
        }
        .frame(minWidth: 40)
    }

    private func chipColor(_ level: Float) -> Color {
        if level > 0.6 { return .red }
        if level > 0.3 { return .orange }
        if level > 0.1 { return .yellow }
        return .green
    }
}
