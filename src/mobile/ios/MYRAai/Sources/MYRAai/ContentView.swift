import SwiftUI

struct ContentView: View {
    @StateObject private var webViewState = WebViewState()
    @State private var keyboardHeight: CGFloat = 0

    var body: some View {
        ZStack {
            WebView(state: webViewState)
                .ignoresSafeArea()
                .padding(.bottom, keyboardHeight)
                .animation(.easeOut(duration: 0.25), value: keyboardHeight)

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
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                    as? CGRect else { return }
            keyboardHeight = frame.height
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            keyboardHeight = 0
        }
    }
}
