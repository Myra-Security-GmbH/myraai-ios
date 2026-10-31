import WebKit
import UIKit
import AuthenticationServices
import os

// MARK: - Native Bridge (WKScriptMessageHandler)

final class NativeBridge: NSObject, WKScriptMessageHandler {

    private let log = Logger(subsystem: "eu.myra.myraai", category: "bridge")

    static let handlerNames = ["hapticFeedback", "share", "copyToClipboard", "notifyScrollTop",
                               "openAuthSession"]

    /// AGF-3462 / AGF-5511: native-app Google/Microsoft sign-in and connector OAuth (ASWebAuthenticationSession). One per bridge
    /// (= per WebView); its `webView` is wired in WebView.makeUIView.
    let authSession = AuthSessionController()

    private let bridgeLog = Logger(subsystem: "eu.myra.myraai", category: "native-bridge")

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        // AGF-3778: the bridge answers ONLY the app's own top-level page. WebKit delivers a script message
        // from EVERY frame (a sandboxed chat preview can call webkit.messageHandlers.share / copyToClipboard),
        // so each message is checked for its sender frame first: the main frame, https, default port, on an
        // SPA host. Anything else is dropped (logged without its body).
        let frame = message.frameInfo
        guard NavigationPolicy.isAppBridgeFrame(isMainFrame: frame.isMainFrame,
                                             protocol: frame.securityOrigin.protocol,
                                             host: frame.securityOrigin.host,
                                             port: frame.securityOrigin.port) else {
            bridgeLog.warning("bridge: \(message.name, privacy: .public) from a frame that is not the app page; ignored")
            return
        }
        switch message.name {
        case "hapticFeedback": handleHaptic(message.body as? String ?? "light")
        case "share":          handleShare(message.body as? [String: Any] ?? [:])
        case "copyToClipboard":
            if let text = message.body as? String { UIPasteboard.general.string = text }
        case "openAuthSession": authSession.handle(message)
        default: break
        }
    }

    // MARK: - Haptic

    private func handleHaptic(_ type: String) {
        Task { @MainActor in
            switch type {
            case "success":
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "medium":
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            default:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    // MARK: - Share

    private func handleShare(_ body: [String: Any]) {
        let text = body["text"] as? String ?? ""
        let urlStr = body["url"] as? String ?? ""
        guard !text.isEmpty || !urlStr.isEmpty else { return }
        var items: [Any] = []
        if !text.isEmpty { items.append(text) }
        if !urlStr.isEmpty, let url = URL(string: urlStr) { items.append(url) }
        Task { @MainActor in
            let activityVC = UIActivityViewController(activityItems: items,
                                                      applicationActivities: nil)
            UIApplication.shared.presentSheet(activityVC, onFailure: { [weak self] in
                self?.log.warning("share: nothing to present from")
            })
        }
    }
}

// MARK: - Native-app OAuth (AGF-3462, AGF-5511, RFC 8252)

// AGF-3462: the UIKit-dependent half of AuthURLPolicy (the rest is Foundation-only, AuthURLPolicy.swift).
extension AuthURLPolicy {
    /// The `window.__myraNativeCaps.oauthSession` value this device advertises, or nil (no cap →
    /// the SPA offers email-code sign-in only). iPhone/iPad on iOS ≥ 17.4: "link" (https callback);
    /// iPhone < 17.4: "scheme" (myraai://, accepted risk, server kill switch
    /// `oauth_app_scheme_return`); iPad < 17.4: nil (iPadOS sends a Mac UA the server cannot
    /// classify for the scheme channel). The bridge handler refuses whenever this is nil.
    static var oauthSessionCap: String? {
        if #available(iOS 17.4, *) { return "link" }
        if UIDevice.current.userInterfaceIdiom == .phone { return "scheme" }
        return nil
    }
}

/// Runs the native sign-in or connector OAuth: the SPA posts the provider authorize URL (sign-in) or the
/// owned connector start hop (AGF-5511) to the `openAuthSession` message handler; this opens it in
/// ASWebAuthenticationSession (system browser, shared Safari cookies) and loads the server's hand-off into
/// the web view when the session returns (the SPA tells the two flows apart by its stored verifier).
///
/// Trust: the message must come from the MAIN frame (model artifacts / MCP apps run script in
/// iframes, and WKScriptMessageHandlers are reachable from every frame) of an owned SPA origin
/// that is also the web view's current host, and the URL must pass `AuthURLPolicy.sessionKind(for:)`
/// (provider authorize URL or the owned connector hop) for that env and this device's channel. Anything
/// else is ignored (logged, URL not logged). One pending session at a time; cancel / error → cleared,
/// nothing loaded.
///
/// Main thread only: WKScriptMessageHandler callbacks arrive there, and the session completion
/// is hopped back with DispatchQueue.main.
final class AuthSessionController: NSObject, ASWebAuthenticationPresentationContextProviding {

    weak var webView: WKWebView?

    // Lifetime: one sign-in. The running session (nil when none is pending) and its SPA host.
    private var session: ASWebAuthenticationSession?
    // Lifetime: from a completion's `webView.load` until the matching decidePolicyFor consumes it.
    // The ONE app-complete navigation native code initiated (see consumeNativeAppCompleteLoad).
    private var nativeAppCompleteURL: URL?

    private let log = Logger(subsystem: "eu.myra.myraai", category: "auth-session")

    #if DEBUG
    /// UI-test observability only (AGF-5511): receives `AUTH …` lines (never the URL). Wired by
    /// WebView.Coordinator to its probe writer, which is active only under -MyraUITestHTML.
    var probe: ((String) -> Void)?
    #endif

    private func report(_ line: String) {
        #if DEBUG
        probe?(line)
        #endif
    }

    func handle(_ message: WKScriptMessage) {
        guard let cap = AuthURLPolicy.oauthSessionCap else {
            log.warning("openAuthSession: no oauthSession capability on this device; ignored")
            report("AUTH refused cap")
            return
        }
        let origin = message.frameInfo.securityOrigin
        guard let webView, webView.window != nil else {
            log.warning("openAuthSession: no web view on screen; ignored")
            report("AUTH refused webview")
            return
        }
        guard NavigationPolicy.isAppBridgeFrame(isMainFrame: message.frameInfo.isMainFrame, protocol: origin.protocol,
                                                host: origin.host, port: origin.port),
              let adminHost = AuthURLPolicy.adminHost(forSPAHost: origin.host) else {
            log.warning("openAuthSession: not from the app's top-level page; ignored")
            report("AUTH refused frame")
            return
        }
        guard NavigationPolicy.isAppPage(isMainFrame: message.frameInfo.isMainFrame, protocol: origin.protocol,
                                         host: origin.host, port: origin.port, webViewHost: webView.url?.host),
              let spaHost = webView.url?.host?.lowercased() else {
            log.warning("openAuthSession: web view host does not match the message origin; ignored")
            report("AUTH refused host")
            return
        }
        guard let raw = message.body as? String,
              let kind = AuthURLPolicy.sessionKind(for: raw, adminHost: adminHost, channel: cap),
              let url = URL(string: raw) else {
            log.warning("openAuthSession: URL not on the authorize / connector allowlist; ignored")
            report("AUTH refused url")
            return
        }
        guard session == nil else {
            log.warning("openAuthSession: a session is already pending; ignored")
            report("AUTH refused pending")
            return
        }
        switch kind {
        case .connector: report("AUTH accepted connector")
        case .provider: report("AUTH accepted provider")
        }
        start(url: url, spaHost: spaHost)
    }

    private func start(url: URL, spaHost: String) {
        let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                self?.finish(callbackURL: callbackURL, error: error, spaHost: spaHost)
            }
        }
        let newSession: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            // Universal-link-free https callback: the session itself matches the redirect to
            // https://<spaHost>/auth/app-complete (requires webcredentials:<spaHost> in the
            // entitlements + AASA), so it cannot be intercepted by another app.
            newSession = ASWebAuthenticationSession(
                url: url,
                callback: .https(host: spaHost, path: AuthURLPolicy.appCompletePath),
                completionHandler: completion)
        } else {
            newSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: AuthURLPolicy.returnScheme,
                completionHandler: completion)
        }
        newSession.presentationContextProvider = self
        // Shared Safari cookies: the user's existing Google/Microsoft session is reused.
        newSession.prefersEphemeralWebBrowserSession = false
        session = newSession
        if newSession.start() {
            report("AUTH opened")
        } else {
            log.error("openAuthSession: ASWebAuthenticationSession failed to start")
            report("AUTH start-failed")
            session = nil
        }
    }

    private func finish(callbackURL: URL?, error: Error?, spaHost: String) {
        session = nil
        if let error {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                log.info("openAuthSession: cancelled by the user")
                report("AUTH done cancelled")
            } else {
                log.error("openAuthSession: session failed: \(error.localizedDescription, privacy: .public)")
                report("AUTH done error")
            }
            return
        }
        guard let callbackURL,
              let target = AuthURLPolicy.completionURL(for: callbackURL, spaHost: spaHost) else {
            log.warning("openAuthSession: callback URL rejected; nothing loaded")
            report("AUTH done rejected")
            return
        }
        guard let webView else {
            log.warning("openAuthSession: web view gone before the completion could load; nothing loaded")
            report("AUTH done no-webview")
            return
        }
        nativeAppCompleteURL = target
        report("AUTH done loaded")
        webView.load(URLRequest(url: target))
    }

    /// Called by the navigation delegate for a MAIN-frame navigation to the app-complete route:
    /// true (allow) only for the one load `finish` just started — same host and the same
    /// fragment (the fragment carries the single-use hand-off, so nothing else can match it).
    /// One-shot: consumed on the match. Everything else (a planted link, a redirect,
    /// window.open) → false (cancel) and does NOT consume, so a page racing its own navigation in
    /// cannot get the native load cancelled.
    func consumeNativeAppCompleteLoad(_ url: URL) -> Bool {
        guard let expected = nativeAppCompleteURL,
              url.host?.lowercased() == expected.host?.lowercased(),
              url.fragment == expected.fragment else { return false }
        nativeAppCompleteURL = nil
        return true
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `handle` only starts a session while the web view is in a window.
        webView?.window ?? ASPresentationAnchor()
    }
}
