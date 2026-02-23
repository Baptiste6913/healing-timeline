import SwiftUI

struct ProcessingView: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(2)
                .tint(.cyan)

            Text("Processing your scan...")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white)

            Text("Building 3D mesh and preparing simulation")
                .font(.system(size: 15))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }
}
