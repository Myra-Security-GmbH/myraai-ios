import SwiftUI

struct ContentView: View {
    @StateObject private var webViewState = WebViewState()

    var body: some View {
        ZStack {
            WebView(state: webViewState)
                .ignoresSafeArea()

            if webViewState.showOffline {
                OfflineView {
                    webViewState.reload()
                }
                .ignoresSafeArea()
            }

            if !webViewState.isLoaded && !webViewState.showOffline {
                LaunchOverlay()
                    .ignoresSafeArea()
            }
        }
        .preferredColorScheme(nil)
    }
}
