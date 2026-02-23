import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch appState.currentScreen {
            case .splash:
                SplashView()
            case .scan:
                ScanView()
            case .processing:
                ProcessingView()
            case .viewer:
                ViewerScreen()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $appState.showDisclaimer) {
            DisclaimerView()
        }
    }
}
