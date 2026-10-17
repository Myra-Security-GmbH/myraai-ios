import Foundation

/// AGF-3766 — the ONE navigation policy of the app's web view (decidePolicyFor and createWebViewWith both ask it).
///
/// Pure: no WebKit / UIKit types, so the whole matrix is unit-tested (MYRAaiTests/NavigationPolicyTests).
///
/// The rule that closes AGF-3766: a navigation whose TARGET is a subframe is never handed to the system (Safari,
/// Messages, another app). Measured on the simulator (NavigationGuards): a subframe navigation reaches the policy
/// delegate BEFORE WebKit applies the embedder's CSP `frame-src`, and the old policy opened every non-owned host
/// in Safari — the unfenced preview's `location.href = "https://x/?d=<data>"` and the sign-up captcha's own frame
/// (`cdn.eu-captcha.eu`) both landed in Safari. A subframe navigation now either loads IN its frame, where the
/// embedder's CSP stays the authority (the captcha, the admin-host PDF frame, an owned frame's redirect), or is
/// cancelled: when the target frame is a sandboxed (opaque-origin) document — a preview — any network
/// navigation of it is cancelled, whatever the host; a non-web scheme from any subframe is cancelled.
///
/// Main frame and new-window requests keep the previous behaviour: owned hosts load in place, external schemes and
/// non-owned hosts go to the system (a link the app renders and the user taps); a host-less new-window request is
/// dropped (the app has no second web view to put it in).
enum NavigationPolicy {

    enum Decision: Equatable {
        case allow           // load in the web view (in its frame)
        case cancel          // drop it — nothing loads, nothing is handed off
        case openExternally  // cancel here and hand the URL to the system
    }

    /// Which frame the navigation would load into.
    enum Target: Equatable {
        case mainFrame
        case newWindow                    // window.open / target=_blank (WKNavigationAction.targetFrame == nil)
        case subframe(opaqueOrigin: Bool) // opaqueOrigin: the frame's CURRENT document has no host (sandboxed)
    }

    // ai-int.* included so the CI base-URL override (int-targeted smoke) navigates in-app instead of bouncing to
    // Safari; the int hosts are ours.
    static let ownedHosts = ["ai.myra.eu", "ai-api.myra.eu", "ai-api-admin.myra.eu",
                             "ai-int.myra.eu", "ai-api-admin-int.myra.eu"]

    // Non-web schemes a web view cannot load itself — handed to the system (mail/phone/SMS/maps app) when the
    // app's own page asks. Deliberately an allowlist.
    static let externalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio", "maps"]

    /// Owned SPA host → that env's admin-API host (the OAuth redirect_uri host, AGF-3462). The SPA hosts are
    /// also the only pages the native bridge answers (AGF-3778).
    static let adminHostBySPAHost = [
        "ai.myra.eu": "ai-api-admin.myra.eu",
        "ai-int.myra.eu": "ai-api-admin-int.myra.eu",
    ]

    /// AGF-3778: the ONE sender check of every native-bridge message (NativeBridge's handlers and the sign-in
    /// bridge): the app's own top-level page — the main frame, https, the default port, an SPA host. A sandboxed
    /// preview (opaque origin: empty protocol and host) or any subframe fails it.
    static func isAppBridgeFrame(isMainFrame: Bool, protocol scheme: String, host: String, port: Int) -> Bool {
        isMainFrame && scheme.lowercased() == "https" && port == 0 && adminHostBySPAHost[host.lowercased()] != nil
    }

    // Schemes a frame loads in place without a network request.
    private static let localSchemes: Set<String> = ["about", "blob", "data"]

    static func isOwned(_ host: String) -> Bool {
        let h = host.lowercased()
        return ownedHosts.contains(where: { h == $0 || h.hasSuffix(".\($0)") })
    }

    /// An owned host loads in the web view only over http(s); `foo://ai.myra.eu/…` is any other app link.
    private static func isOwnedWeb(_ scheme: String, _ host: String) -> Bool {
        (scheme == "https" || scheme == "http") && isOwned(host)
    }

    static func decide(url: URL?, target: Target) -> Decision {
        guard let url else { return .allow }   // WebKit-internal (no request URL): nothing to hand off
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        switch target {
        case .subframe(let opaqueOrigin):
            if localSchemes.contains(scheme) { return .allow }
            guard scheme == "https" || scheme == "http", !host.isEmpty else { return .cancel }
            if opaqueOrigin { return .cancel }          // a sandboxed preview navigating itself
            return .allow                               // in place; the embedder's CSP frame-src decides
        case .mainFrame:
            if externalSchemes.contains(scheme) { return .openExternally }
            if host.isEmpty { return .allow }           // about:/blob:/data: — unchanged
            return isOwnedWeb(scheme, host) ? .allow : .openExternally
        case .newWindow:
            // The app has one web view: an owned URL loads in place, a hand-off goes to the system, anything
            // without a host (window.open() / about:blank / blob:) has nowhere to go.
            if externalSchemes.contains(scheme) { return .openExternally }
            if host.isEmpty { return .cancel }
            return isOwnedWeb(scheme, host) ? .allow : .openExternally
        }
    }
}
