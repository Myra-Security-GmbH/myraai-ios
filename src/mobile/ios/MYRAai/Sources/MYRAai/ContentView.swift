import SwiftUI

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

            // XCUITest screenshot hooks — only rendered when launched with SCREENSHOT_MODE.
            // XCUITest touch synthesis and AXPress both fail to fire onClick on React elements
            // portaled to document.body (Xcode 26 / iOS 26 WKWebView limitation).
            // Native SwiftUI buttons call evaluateJavaScript so the click fires directly
            // into the browser event system, bypassing the UIKit→WebKit touch pipeline.
            if ProcessInfo.processInfo.arguments.contains("SCREENSHOT_MODE") {
                VStack {
                    Spacer()
                    HStack {
                        Button("open-sidebar-hook") {
                            Task { @MainActor in
                                webViewState.webView?.evaluateJavaScript(
                                    "document.querySelector(\"button[aria-label='Open navigation menu']\")?.click()",
                                    completionHandler: nil
                                )
                            }
                        }
                        .accessibilityIdentifier("screenshot_open_sidebar")
                        .frame(width: 44, height: 44)
                        .opacity(0.001)

                        Spacer()

                        Button("nav-chat-hook") {
                            Task { @MainActor in
                                webViewState.webView?.evaluateJavaScript(
                                    "document.querySelector(\"a[href='/chat']\")?.click()",
                                    completionHandler: nil
                                )
                            }
                        }
                        .accessibilityIdentifier("screenshot_nav_chat")
                        .frame(width: 44, height: 44)
                        .opacity(0.001)
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
            case .background:
                // Instant — no animation wrapper, must beat app-switcher screenshot
                showPrivacyShield = true
                backgroundedAt = Date()
            case .active:
                if let date = backgroundedAt {
                    if Date().timeIntervalSince(date) > 30 * 60 {
                        isLocked = true
                    } else {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showPrivacyShield = false
                        }
                    }
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }
}

// MARK: - Privacy Shield

private struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color(red: 13/255, green: 27/255, blue: 42/255)
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .accessibilityHidden(true)
        }
    }
}
