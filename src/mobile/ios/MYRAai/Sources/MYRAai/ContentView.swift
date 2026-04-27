import SwiftUI

struct ContentView: View {
    @StateObject private var webViewState = WebViewState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundedAt: Date?

    var body: some View {
        ZStack {
            WebView(state: webViewState)
                .ignoresSafeArea()

            if webViewState.showOffline {
                OfflineView { webViewState.reload() }
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            if !webViewState.isLoaded && !webViewState.showOffline {
                LaunchOverlay()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: webViewState.isLoaded)
        .animation(.easeOut(duration: 0.2), value: webViewState.showOffline)
        .preferredColorScheme(nil)
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                backgroundedAt = Date()
            case .active:
                if let date = backgroundedAt, Date().timeIntervalSince(date) > 30 * 60 {
                    webViewState.reload()
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }
}
