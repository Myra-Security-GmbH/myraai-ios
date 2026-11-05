import Foundation

// MARK: - Native-app OAuth policy (AGF-3462, AGF-5511, RFC 8252)

/// Pure policy for the native sign-in: which authorize URLs the bridge may open, which callbacks
/// may complete it, and which path only native code may load. No state, no UIKit except the cap.
/// Mirrors Android's `Deeplinks.isAllowedAuthorizeUrl` / `isAppCompletePath` — keep the two in
/// step (the Android copy is JVM unit- and fuzz-tested; iOS: AuthURLPolicyTests). Foundation-only on
/// purpose: this file is compiled into the MYRAaiTests logic bundle; the UIKit-dependent
/// `oauthSessionCap` lives in NativeBridge.swift.
enum AuthURLPolicy {

    /// SPA route that redeems an app hand-off. Only ever loaded by native code during a pending
    /// session (AuthSessionController); every other main-frame navigation to it is cancelled.
    static let appCompletePath = "/auth/app-complete"

    /// iOS < 17.4 return scheme. NOT registered in CFBundleURLTypes: ASWebAuthenticationSession
    /// catches it inside its own browser, so nothing else can drive the app with it.
    static let returnScheme = "myraai"

    static func adminHost(forSPAHost host: String?) -> String? {
        guard let h = host?.lowercased() else { return nil }
        return NavigationPolicy.adminHostBySPAHost[h]
    }

    /// Which kind of session the bridge may start for a posted URL.
    enum SessionKind: Equatable {
        case provider   // Google / Microsoft sign-in authorize URL (AGF-3462)
        case connector  // the owned connector start hop (AGF-5507 / AGF-5511)
    }

    /// The ONE gate of `openAuthSession`: the kind of session `raw` may start for the env whose admin host
    /// is `adminHost` on a device advertising `channel`, or nil (refused). Provider hosts other than the two
    /// sign-in endpoints are never accepted: a connector's provider is reached only via the owned hop.
    static func sessionKind(for raw: String, adminHost: String, channel: String) -> SessionKind? {
        if isAllowedAuthorizeURL(raw, adminHost: adminHost) { return .provider }
        if isAllowedConnectorStartURL(raw, adminHost: adminHost, channel: channel) { return .connector }
        return nil
    }

    private static let connectorStartPath = "/admin/auth/mcp/app-authorize?id=g"
    private static let connectorIdHexLength = 32

    /// The connector-id letter bound to a device `channel` ("link" → l, "scheme" → s), or nil when that channel
    /// cannot take the connector hop. The ONE decision for "which caps accept the connector hop": used by
    /// `isAllowedConnectorStartURL` and by `oauthCapsJS`.
    static func connectorChannelLetter(for channel: String) -> String? {
        switch channel {
        case "link": return "l"
        case "scheme": return "s"
        default: return nil
        }
    }

    /// AGF-5651: the capability fragment appended inside `window.__myraNativeCaps = { microphone: true… }`, from
    /// `cap` (always `AuthURLPolicy.oauthSessionCap`, a constant "link"/"scheme" — never untrusted input).
    /// "" for nil (no native sign-in: iPad < 17.4). Otherwise `, oauthSession: "<cap>"`, plus `, connectorOAuth: true`
    /// exactly when `connectorChannelLetter(for: cap)` is non-nil, i.e. when this build's `openAuthSession` bridge
    /// accepts the owned connector start hop (`sessionKind` → `.connector`). Tied to the cap because the bridge
    /// refuses everything without one. It advertises the BRIDGE's ability only; the server kill switch
    /// `oauth_app_scheme_return` still applies to cap "scheme". Same key and boolean as Android.
    static func oauthCapsJS(cap: String?) -> String {
        guard let cap = cap else { return "" }
        var js = ", oauthSession: \"\(cap)\""
        if connectorChannelLetter(for: cap) != nil { js += ", connectorOAuth: true" }
        return js
    }

    /// AGF-5511: the owned connector start hop of AGF-5507 — EXACTLY
    /// `https://<adminHost>/admin/auth/mcp/app-authorize?id=g<letter><32 lowercase hex>`, the letter bound to
    /// the device's `channel` ("link" → l, "scheme" → s; anything else → false). A fixed-length byte
    /// comparison (UTF-8, like `isAllowedAuthorizeURL`): no uppercase scheme/host, port, userinfo, second
    /// param, fragment, trailing slash/dot, percent-encoding or whitespace can pass. A `gi…`/`gs…` id on a
    /// link device (whose session could never catch the return) is refused instead of opening a sheet that
    /// can only hang. Mirrors the SPA's `parseOwnedAuthorizeUrl` (which leaves the host to this pin).
    static func isAllowedConnectorStartURL(_ raw: String, adminHost: String, channel: String) -> Bool {
        guard let letter = connectorChannelLetter(for: channel) else { return false }
        let prefix = Array("https://\(adminHost.lowercased())\(connectorStartPath)\(letter)".utf8)
        let bytes = Array(raw.utf8)
        guard bytes.count == prefix.count + connectorIdHexLength, bytes.starts(with: prefix) else { return false }
        return bytes.dropFirst(prefix.count).allSatisfy { ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) ||
            ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) }
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
