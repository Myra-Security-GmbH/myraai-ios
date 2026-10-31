import SwiftUI
import UIKit
import os

// Warm cream/rust brand — matches the web app's design tokens
// (--content-bg #faf9f5, --text-primary #2a2722, --accent #c96442,
// --text-secondary #73706a). The native chrome (launch overlay, offline,
// biometric lock, privacy shield, WebView background) sits on the cream
// surface, so text is dark and the accent buttons keep white labels.
extension Color {
    static let brandBackground = Color(red: 250/255, green: 249/255, blue: 245/255) // #faf9f5
    static let brandText       = Color(red: 42/255,  green: 39/255,  blue: 34/255)  // #2a2722
    static let brandAccent     = Color(red: 201/255, green: 100/255, blue: 66/255)  // #c96442
    static let brandSubtle     = Color(red: 115/255, green: 112/255, blue: 106/255) // #73706a
    static let brandMuted      = Color(red: 138/255, green: 133/255, blue: 121/255) // #8a8579
    static let brandError      = Color(red: 154/255, green: 59/255,  blue: 34/255)  // #9a3b22
}

extension UIColor {
    static let brandBackground = UIColor(red: 250/255, green: 249/255, blue: 245/255, alpha: 1) // #faf9f5
}

struct ContentView: View {
    @StateObject private var webViewState = WebViewState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundedAt: Date?
    @State private var showPrivacyShield = false
    @State private var isLocked = false
    #if DEBUG
    // AGF-3715: the UI-test universal link is delivered at most once per launch.
    @State private var uiTestUserActivityDelivered = false
    #endif

    // DEBUG-only hook so RegressionGuards T-3 can verify the shield renders and
    // covers the window deterministically. The real trigger fires on .inactive
    // while the app is backgrounded, which XCUITest cannot observe (it can't
    // query a backgrounded app, and the shield is hidden again on .active). In
    // Release this is a constant `false`, so the `|| forcedShieldForUITest`
    // below collapses to the original condition — zero production effect.
    private static var forcedShieldForUITest: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-MyraUITestForceShield")
        #else
        return false
        #endif
    }

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
            // Insertion is instant (.identity) so the cover is already opaque
            // before the app-switcher snapshot is taken; a faded insertion would
            // leak chat content into the thumbnail. Removal still fades, driven
            // by the withAnimation in the .active scene-phase branch below.
            if showPrivacyShield || Self.forcedShieldForUITest {
                PrivacyShieldView()
                    .ignoresSafeArea()
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
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
        // Universal links (applinks:ai.myra.eu): iOS opens the app for any tapped
        // ai.myra.eu link. Without handling it the app would ignore the URL and
        // just show the home screen; point the WebView at the exact path so a
        // shared link lands where it should.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            handleUserActivity(activity)
        }
        // AGF-4244: a tapped push (tool_approval -> the held approval card). Cold start: the tap is parked in
        // AppDelegate before this view exists, so also consume on appear.
        .onAppear { consumePendingPush() }
        .onReceive(NotificationCenter.default.publisher(for: .pushTapped)) { _ in consumePendingPush() }
        #if DEBUG
        // AGF-3715 UI-test hook: deliver `-MyraUITestUserActivityURL <url>` as a universal-link user activity
        // once the page has loaded — through the SAME handler the system's continuation calls.
        .onChange(of: webViewState.isLoaded) { loaded in deliverUITestUserActivity(loaded) }
        #endif
    }

    /// AGF-4244: open the page a tapped push points at. The URL is built by NavigationPolicy from the validated
    /// review id, not taken from the payload, so it deliberately does not go through openDeepLink.
    private func consumePendingPush() {
        guard let userInfo = AppDelegate.takePendingPushUserInfo() else { return }
        guard let url = NavigationPolicy.pushTargetURL(userInfo: userInfo,
                                                       spaHost: webViewState.webView?.url?.host) else { return }
        webViewState.navigate(to: url)
    }

    /// The universal-link continuation (a tapped ai.myra.eu link, e.g. a sign-in / sign-up magic link whose
    /// token rides the fragment — AGF-3715). One entry point for the system and the UI test.
    private func handleUserActivity(_ activity: NSUserActivity) {
        #if DEBUG
        DeepLinkProbe.log.notice("received via=activity route=\(DeepLinkProbe.routeClass(activity.webpageURL), privacy: .public)")
        #endif
        if let url = activity.webpageURL { openDeepLink(url) }
    }

    #if DEBUG
    /// AGF-3715 (DEBUG-only, gated on the launch argument): XCUITest cannot hand the app a universal link (that
    /// needs a signed build with a verified associated domain), so the test passes the URL and the app builds the
    /// NSUserActivity a tapped link would carry, once, after the first page load. Release builds have no such path.
    private func deliverUITestUserActivity(_ loaded: Bool) {
        guard loaded, !uiTestUserActivityDelivered,
              let raw = WebView.launchArgValue("-MyraUITestUserActivityURL"), let url = URL(string: raw) else { return }
        uiTestUserActivityDelivered = true
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        handleUserActivity(activity)
    }
    #endif

    /// Load a tapped ai.myra.eu universal link in the WebView. Guards the host so
    /// only our own first-party URLs are ever loaded into the app shell.
    /// AGF-3462: a link to /auth/app-complete is DROPPED (app stays where it is) — only the
    /// native sign-in completion may load that route (the navigation delegate cancels it too).
    private func openDeepLink(_ url: URL) {
        guard let target = NavigationPolicy.universalLinkTarget(url) else {
            #if DEBUG
            DeepLinkProbe.log.notice("gated outcome=dropped")
            #endif
            return
        }
        #if DEBUG
        DeepLinkProbe.log.notice("gated outcome=load route=\(DeepLinkProbe.routeClass(target), privacy: .public)")
        #endif
        webViewState.navigate(to: target)
    }
}

#if DEBUG
/// AGF-5758 (DEBUG-only) — the deep-link delivery probes the `deeplink-guard` workflow reads
/// (`log show --info --predicate 'subsystem == "eu.myra.myraai" AND category == "deeplink"'`). A universal link can carry a
/// token in its path, so a probe logs a route CLASS only (never the path, query or fragment), enum tokens `.public`.
enum DeepLinkProbe {
    static let log = Logger(subsystem: "eu.myra.myraai", category: "deeplink")

    static func routeClass(_ url: URL?) -> String {
        switch url?.pathComponents.dropFirst().first {
        case "shared": return "shared"
        case "auth": return "auth"
        case "c": return "c"
        default: return "other"
        }
    }
}
#endif

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
        // .accessibilityElement() collapses the ZStack into ONE element so the
        // identifier attaches to something XCUITest can query — an identifier on
        // a bare container (Color + hidden Image, no accessible children) is not
        // exposed on its own. Needed by RegressionGuards T-3.
        .accessibilityElement()
        .accessibilityIdentifier("myra-privacy-shield")
    }
}
