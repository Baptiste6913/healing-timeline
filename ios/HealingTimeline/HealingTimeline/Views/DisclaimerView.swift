import SwiftUI

struct DisclaimerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20)

                    Text("Important Notice")
                        .font(.system(size: 24, weight: .bold))
                        .frame(maxWidth: .infinity)

                    Group {
                        disclaimerSection(
                            title: "Not Medical Advice",
                            text: "This application provides illustrative simulations only. It does not provide medical advice, diagnosis, or treatment recommendations."
                        )

                        disclaimerSection(
                            title: "Simulation Limitations",
                            text: "The healing timeline shown is based on general population averages from published literature. Individual recovery varies significantly based on surgical technique, anatomy, health status, and many other factors."
                        )

                        disclaimerSection(
                            title: "Consult Your Surgeon",
                            text: "Always consult your qualified healthcare provider for questions about your specific recovery. Do not make medical decisions based on this simulation."
                        )

                        disclaimerSection(
                            title: "Privacy",
                            text: "All face scan data is processed and stored locally on your device. No data is transmitted to any server."
                        )
                    }
                }
                .padding(24)
            }
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("I Understand") {
                        appState.showDisclaimer = false
                    }
                    .font(.system(size: 16, weight: .semibold))
                }
            }
        }
    }

    private func disclaimerSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
        }
    }
}
