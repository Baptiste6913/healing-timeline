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

            // Day label
            HStack {
                Text(viewerVM.dayLabel)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                // Swelling indicator
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Swelling")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    Text("\(Int(viewerVM.currentState.swellingLevel * 100))%")
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundColor(swellingColor)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)

            // 3D Viewer
            MeshViewerRepresentable(
                meshData: viewerVM.displayMesh,
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

    private var swellingColor: Color {
        let level = viewerVM.currentState.swellingLevel
        if level > 0.6 { return .red }
        if level > 0.3 { return .orange }
        if level > 0.1 { return .yellow }
        return .green
    }
}
