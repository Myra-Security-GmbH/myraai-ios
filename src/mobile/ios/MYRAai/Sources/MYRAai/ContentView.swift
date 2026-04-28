import SwiftUI
import UIKit

extension Color {
    static let brandBackground = Color(red: 13/255, green: 27/255, blue: 42/255)
    static let brandAccent     = Color(red: 0.36, green: 0.77, blue: 0.92)
    static let brandSubtle     = Color(red: 0.49, green: 0.70, blue: 0.83)
    static let brandMuted      = Color(red: 0.62, green: 0.69, blue: 0.75)
    static let brandError      = Color(red: 0.9, green: 0.4, blue: 0.4)
}

extension UIColor {
    static let brandBackground = UIColor(red: 13/255, green: 27/255, blue: 42/255, alpha: 1)
}

struct ContentView: View {
    @StateObject private var webViewState = WebViewState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundedAt: Date?
    @State private var showPrivacyShield = false
    @State private var isLocked = false

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

            // Privacy shield — covers content immediately when backgrounded.
            // No appear-transition: must be instant to beat the app-switcher screenshot.
            if showPrivacyShield {
                PrivacyShieldView()
                    .ignoresSafeArea()
                    .transition(.opacity.animation(.easeOut(duration: 0.25)))
            }

            // Biometric lock — shown after long background absence.
            if isLocked {
                BiometricLockView {
                    withAnimation(.easeOut(duration: 0.25)) {
                        isLocked = false
                        showPrivacyShield = false
                    }
                }
                .ignoresSafeArea()
            }

        }
        .animation(.easeOut(duration: 0.3), value: webViewState.isLoaded)
        .animation(.easeOut(duration: 0.2), value: webViewState.showOffline)
        .preferredColorScheme(nil)
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .inactive:
                // Beat the app-switcher snapshot — .inactive fires before .background.
                showPrivacyShield = true
            case .background:
                backgroundedAt = Date()
            case .active:
                if let date = backgroundedAt, Date().timeIntervalSince(date) > 30 * 60 {
                    isLocked = true
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { showPrivacyShield = false }
                }
                backgroundedAt = nil
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Privacy Shield

private struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color.brandBackground
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("myra-privacy-shield")
    }
}
