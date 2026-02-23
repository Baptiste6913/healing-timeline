import SwiftUI

struct SplashView: View {
    @EnvironmentObject var appState: AppState
    @State private var animateIn = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo / Title
            VStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 64))
                    .foregroundStyle(.linearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                Text("Healing Timeline")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("by Rhinovate")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.gray)
            }
            .opacity(animateIn ? 1 : 0)
            .offset(y: animateIn ? 0 : 20)

            Spacer()

            // Subtitle
            Text("Visualize your recovery journey")
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .opacity(animateIn ? 1 : 0)

            // Start button
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    appState.currentScreen = .scan
                }
            } label: {
                Text("Start Face Scan")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(16)
            }
            .padding(.horizontal, 24)
            .opacity(animateIn ? 1 : 0)

            // Use sample mesh (dev)
            Button {
                Task {
                    appState.capturedMesh = SampleMeshLoader.loadSampleMesh()
                    withAnimation {
                        appState.currentScreen = .viewer
                    }
                }
            } label: {
                Text("Use Sample Mesh (Demo)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.cyan)
            }
            .opacity(animateIn ? 1 : 0)

            Spacer()
                .frame(height: 40)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                animateIn = true
            }
        }
    }
}
