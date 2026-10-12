import WebKit
import UIKit
import AuthenticationServices
import os

// MARK: - Native Bridge (WKScriptMessageHandler)

final class NativeBridge: NSObject, WKScriptMessageHandler {

    static let handlerNames = ["hapticFeedback", "share", "copyToClipboard", "notifyScrollTop",
                               "openAuthSession"]

    /// AGF-3462: native-app Google/Microsoft sign-in (ASWebAuthenticationSession). One per bridge
    /// (= per WebView); its `webView` is wired in WebView.makeUIView.
    let authSession = AuthSessionController()

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
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
            guard let root = UIApplication.shared.keyWindow?.rootViewController else { return }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = root.view
                popover.sourceRect = CGRect(x: root.view.bounds.midX,
                                            y: root.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            root.present(activityVC, animated: true)
        }
    }
}

// MARK: - Native-app OAuth (AGF-3462, RFC 8252)

/// Pure policy for the native sign-in: which authorize URLs the bridge may open, which callbacks
/// may complete it, and which path only native code may load. No state, no UIKit except the cap.
/// Mirrors Android's `Deeplinks.isAllowedAuthorizeUrl` / `isAppCompletePath` — keep the two in
/// step (the Android copy is JVM unit- and fuzz-tested; there is no iOS unit target).
enum AuthURLPolicy {

    /// SPA route that redeems an app hand-off. Only ever loaded by native code during a pending
    /// session (AuthSessionController); every other main-frame navigation to it is cancelled.
    static let appCompletePath = "/auth/app-complete"

    /// iOS < 17.4 return scheme. NOT registered in CFBundleURLTypes: ASWebAuthenticationSession
    /// catches it inside its own browser, so nothing else can drive the app with it.
    static let returnScheme = "myraai"

    /// Owned SPA host → that env's admin-API host (the OAuth redirect_uri host).
    private static let adminHostBySPAHost = [
        "ai.myra.eu": "ai-api-admin.myra.eu",
        "ai-int.myra.eu": "ai-api-admin-int.myra.eu",
    ]

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

    static func adminHost(forSPAHost host: String?) -> String? {
        guard let h = host?.lowercased() else { return nil }
        return adminHostBySPAHost[h]
    }

    // Provider authorize endpoints — EXACT scheme+host+path, each bound to its own callback path.
    private static let authorizeEndpoints: [(prefix: String, provider: String)] = [
        ("https://accounts.google.com/o/oauth2/v2/auth?", "google"),
        ("https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize?", "microsoft"),
    ]
    private static let maxAuthorizeURLBytes = 4096

    /// True when `raw` is a provider authorize URL the bridge may open for the env whose admin
    /// host is `adminHost`: exactly one of the two endpoints, a query of only RFC 3986 unreserved
    /// chars / percent escapes / `&` `=` `+` (the server builds it with ngx.escape_uri — anything
    /// else, incl. a fragment, is rejected so no parser differential with the browser), and
    /// exactly ONE `redirect_uri` decoding to `https://<adminHost>/admin/auth/<provider>/callback`.
    /// Works on UTF-8 bytes, not Characters (Swift String comparison is Unicode-canonical).
    static func isAllowedAuthorizeURL(_ raw: String, adminHost: String) -> Bool {
        let bytes = Array(raw.utf8)
        guard bytes.count <= maxAuthorizeURLBytes else { return false }
        guard let endpoint = authorizeEndpoints.first(where: { bytes.starts(with: Array($0.prefix.utf8)) })
        else { return false }
        let query = bytes.dropFirst(endpoint.prefix.utf8.count)
        guard !query.isEmpty, query.allSatisfy(isAuthorizeQueryByte) else { return false }
        var redirect: String?
        var redirectCount = 0
        for pair in query.split(separator: UInt8(ascii: "&"), omittingEmptySubsequences: false) {
            // "", "=x", "flag" → malformed.
            guard let eq = pair.firstIndex(of: UInt8(ascii: "=")), eq != pair.startIndex else { return false }
            if Array(pair[pair.startIndex..<eq]) == Array("redirect_uri".utf8) {
                redirectCount += 1
                guard let decoded = percentDecodeStrict(Array(pair[(eq + 1)...])) else { return false }
                redirect = decoded
            }
        }
        // Absent AND repeated both reject.
        return redirectCount == 1 && redirect == "https://\(adminHost)/admin/auth/\(endpoint.provider)/callback"
    }

    /// The URL to load into the web view for a session callback, or nil (ignored):
    /// - `https://<spaHost>/auth/app-complete#…` (iOS ≥ 17.4) → as-is, host + path re-checked;
    /// - `myraai://oauth?<q>` (iOS < 17.4) → `https://<spaHost>/auth/app-complete#<q>`, only when
    ///   q ≤ 1024 bytes of `[A-Za-z0-9=&_-]` (the SPA parses the fragment strictly on top).
    static func completionURL(for callback: URL, spaHost: String) -> URL? {
        guard let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased() else { return nil }
        guard comps.port == nil, comps.user == nil, comps.password == nil else { return nil }
        switch scheme {
        case "https":
            guard comps.host?.lowercased() == spaHost.lowercased(),
                  comps.percentEncodedPath == appCompletePath else { return nil }
            return callback
        case returnScheme:
            guard comps.host?.lowercased() == "oauth",
                  comps.percentEncodedPath.isEmpty,
                  comps.fragment == nil,
                  let q = comps.percentEncodedQuery,
                  q.utf8.count <= 1024,
                  q.utf8.allSatisfy(isReturnQueryByte) else { return nil }
            return URL(string: "https://\(spaHost.lowercased())\(appCompletePath)#\(q)")
        default:
            return nil
        }
    }

    /// True when `path` (percent-encoded or not) addresses `/auth/app-complete` the way a browser
    /// + the SPA router could still resolve it: case-insensitive, `\\` as `/`, escapes decoded,
    /// empty / `.` segments dropped, `..` applied, trailing slash ignored. Errs wide (blocking a
    /// load is safe; missing one is not). Mirrors Android `Deeplinks.isAppCompletePath`.
    static func isAppCompletePath(_ path: String) -> Bool {
        let b = Array(path.utf8)
        var decoded: [UInt8] = []
        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "%"), i + 2 < b.count,
               let hi = hexValue(b[i + 1]), let lo = hexValue(b[i + 2]) {
                decoded.append(UInt8(hi * 16 + lo))
                i += 3
            } else {
                decoded.append(b[i])
                i += 1
            }
        }
        let normalized = String(decoding: decoded, as: UTF8.self)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        var segments: [String] = []
        for seg in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." {
                if !segments.isEmpty { segments.removeLast() }
                continue
            }
            segments.append(String(seg))
        }
        return segments == ["auth", "app-complete"]
    }

    /// `isAppCompletePath` for a URL, on its percent-encoded path (so an escape the SPA router
    /// would decode cannot slip past).
    static func isAppCompleteURL(_ url: URL) -> Bool {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return isAppCompletePath(path)
    }

    // MARK: byte helpers

    private static func isAuthorizeQueryByte(_ c: UInt8) -> Bool {
        isAlnum(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "_") || c == UInt8(ascii: "~") ||
            c == UInt8(ascii: "%") || c == UInt8(ascii: "+") || c == UInt8(ascii: "=") ||
            c == UInt8(ascii: "&") || c == UInt8(ascii: "-")
    }

    private static func isReturnQueryByte(_ c: UInt8) -> Bool {
        isAlnum(c) || c == UInt8(ascii: "=") || c == UInt8(ascii: "&") ||
            c == UInt8(ascii: "_") || c == UInt8(ascii: "-")
    }

    private static func isAlnum(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z")) ||
            (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) ||
            (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
    }

    /// Value of one ASCII hex digit, or nil.
    private static func hexValue(_ c: UInt8) -> Int? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(c - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(c - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }

    /// Decode `%XX`; nil on a malformed escape, NUL or a non-ASCII byte. `+` stays literal.
    private static func percentDecodeStrict(_ b: [UInt8]) -> String? {
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "%") {
                guard i + 2 < b.count, let hi = hexValue(b[i + 1]), let lo = hexValue(b[i + 2]) else { return nil }
                let v = hi * 16 + lo
                guard v != 0, v <= 0x7e else { return nil }
                out.append(UInt8(v))
                i += 3
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return String(bytes: out, encoding: .ascii)
    }
}

/// Runs the native sign-in: the SPA posts the provider authorize URL to the `openAuthSession`
/// message handler; this opens it in ASWebAuthenticationSession (system browser, shared Safari
/// cookies) and loads the server's hand-off into the web view when the session returns.
///
/// Trust: the message must come from the MAIN frame (model artifacts / MCP apps run script in
/// iframes, and WKScriptMessageHandlers are reachable from every frame) of an owned SPA origin
/// that is also the web view's current host, and the URL must pass
/// `AuthURLPolicy.isAllowedAuthorizeURL` for that env. Anything else is ignored (logged, URL not
/// logged). One pending session at a time; cancel / error → cleared, nothing loaded.
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

    func handle(_ message: WKScriptMessage) {
        guard AuthURLPolicy.oauthSessionCap != nil else {
            log.warning("openAuthSession: no oauthSession capability on this device; ignored")
            return
        }
        guard message.frameInfo.isMainFrame else {
            log.warning("openAuthSession: message from a sub-frame ignored")
            return
        }
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol == "https", origin.port == 0,
              let adminHost = AuthURLPolicy.adminHost(forSPAHost: origin.host) else {
            log.warning("openAuthSession: origin is not an owned SPA origin; ignored")
            return
        }
        guard let webView, webView.window != nil,
              let spaHost = webView.url?.host?.lowercased(), spaHost == origin.host.lowercased() else {
            log.warning("openAuthSession: web view host does not match the message origin; ignored")
            return
        }
        guard let raw = message.body as? String,
              AuthURLPolicy.isAllowedAuthorizeURL(raw, adminHost: adminHost),
              let url = URL(string: raw) else {
            log.warning("openAuthSession: URL not on the authorize allowlist; ignored")
            return
        }
        guard session == nil else {
            log.warning("openAuthSession: a sign-in session is already pending; ignored")
            return
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
        if !newSession.start() {
            log.error("openAuthSession: ASWebAuthenticationSession failed to start")
            session = nil
        }
    }

    private func finish(callbackURL: URL?, error: Error?, spaHost: String) {
        session = nil
        if let error {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                log.info("openAuthSession: cancelled by the user")
            } else {
                log.error("openAuthSession: session failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard let callbackURL,
              let target = AuthURLPolicy.completionURL(for: callbackURL, spaHost: spaHost) else {
            log.warning("openAuthSession: callback URL rejected; nothing loaded")
            return
        }
        guard let webView else { return }
        nativeAppCompleteURL = target
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
