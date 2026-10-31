import XCTest

/// AGF-5511 — unit matrix of AuthURLPolicy (the source file is compiled into this logic-test bundle; no app
/// host, no simulator UI): the owned connector start hop (AGF-5507), the one gate `sessionKind`, and the
/// unchanged provider / completion rules. The on-device proof is ConnectorAuthGuards (UI tests).
final class AuthURLPolicyTests: XCTestCase {

    private let prod = "ai-api-admin.myra.eu"
    private let int = "ai-api-admin-int.myra.eu"
    private let hex = "0123456789abcdef0123456789abcdef"   // 32 lowercase hex

    private func hop(host: String? = nil, id: String) -> String {
        "https://\(host ?? prod)/admin/auth/mcp/app-authorize?id=\(id)"
    }

    private func connector(_ raw: String, host: String? = nil, channel: String = "link") -> Bool {
        AuthURLPolicy.isAllowedConnectorStartURL(raw, adminHost: host ?? prod, channel: channel)
    }

    // MARK: accepted

    func test_connector_hop_accepted_for_both_envs_and_channels() {
        for (h, ch, letter) in [(prod, "link", "l"), (prod, "scheme", "s"), (int, "link", "l"), (int, "scheme", "s")] {
            XCTAssertTrue(connector(hop(host: h, id: "g\(letter)\(hex)"), host: h, channel: ch), "\(h) \(ch)")
        }
    }

    // MARK: env / host pin

    func test_connector_hop_is_pinned_to_the_envs_admin_host() {
        let good = "gl\(hex)"
        XCTAssertFalse(connector(hop(host: int, id: good)))                         // other env's admin host
        XCTAssertFalse(connector(hop(host: int, id: good), host: prod))
        XCTAssertFalse(connector(hop(host: "ai.myra.eu", id: good)))                // the SPA host
        XCTAssertFalse(connector(hop(host: "\(prod).evil.example", id: good)))
        XCTAssertFalse(connector("https://evil.example/\(prod)/admin/auth/mcp/app-authorize?id=\(good)"))
        XCTAssertFalse(connector(hop(host: "evil.example", id: good)))
        XCTAssertFalse(connector("https://todoist.com/oauth/authorize?client_id=x&state=y"))
    }

    func test_connector_hop_rejects_scheme_host_port_userinfo_forms() {
        let id = "gl\(hex)"
        let path = "/admin/auth/mcp/app-authorize?id=\(id)"
        for u in ["http://\(prod)\(path)", "HTTPS://\(prod)\(path)", "https://\(prod.uppercased())\(path)",
                  "https://\(prod):443\(path)", "https://\(prod):8443\(path)", "https://u@\(prod)\(path)",
                  "https://u:p@\(prod)\(path)", "https://\(prod).\(path)", "https://\(prod)@evil.example\(path)",
                  "//\(prod)\(path)", "\(prod)\(path)", "myraai://oauth?id=\(id)"] {
            XCTAssertFalse(connector(u), u)
        }
    }

    // MARK: path

    func test_connector_hop_rejects_wrong_paths() {
        let id = "gl\(hex)"
        for p in ["/admin/auth/mcp/app-authorize/", "/Admin/auth/mcp/app-authorize", "/admin/auth/mcp/App-Authorize",
                  "/admin/auth/mcp%2Fapp-authorize", "/admin/auth/mcp/app-authorize%2F", "/admin/auth/mcp/../mcp/app-authorize",
                  "/admin/auth/mcp/app-authorize/..", "/admin/auth/mcp/app-authorize;x", "/admin/auth/mcp/app-authorise",
                  "/admin/auth/google/callback", "/admin/auth/mcp/callback", "/", ""] {
            XCTAssertFalse(connector("https://\(prod)\(p)?id=\(id)"), p)
        }
        XCTAssertFalse(connector("https://\(prod)/admin/auth/mcp/app-authorize"))           // no query at all
        XCTAssertFalse(connector("https://\(prod)/admin/auth/mcp/app-authorize?"))
    }

    // MARK: id shape

    func test_connector_hop_rejects_malformed_ids() {
        let up = "0123456789ABCDEF0123456789ABCDEF"
        let ids = [
            "", "g", "gl", "gl\(hex.dropLast())", "gl\(hex)0", "gl\(hex)\(hex)",          // absent / empty / 31 / 33 / 64
            "al\(hex)", "Gl\(hex)", "Gl\(up)", "l\(hex)", "\(hex)", "gx\(hex)", "gL\(hex)",   // wrong prefix / unknown letter
            "gl\(up)", "gl0123456789abcdef0123456789abcdeF",                                 // uppercase hex
            "gl0123456789abcdef0123456789abcdez", "gl0123456789abcdef0123456789abcde-",     // non-hex
            "gl0123456789abcdef0123456789abcd%30", "gl%30123456789abcdef0123456789abcdef", // percent-encoded
            "%67l\(hex)", "g%6c\(hex)",
            "gl\(hex)&id=gl\(hex)", "id=gl\(hex)", "gl\(hex)&x=1", "gl\(hex)#x", "gl\(hex)#",
            "gl\(hex) ", " gl\(hex)", "gl\(hex)\n", "gl\(hex)\r\n", "gl\(hex)\t", "gl\(hex)\u{0}",
            "gl\(hex.dropLast())\u{e9}", "gl\(hex.dropLast())\u{ff10}", "gl\(hex)\u{200b}",
        ]
        for id in ids {
            XCTAssertFalse(connector(hop(id: id)), id.debugDescription)
        }
        // repeated / extra / leading params, fragment and trailing junk around a valid id
        let good = "gl\(hex)"
        for u in ["\(hop(id: good))&id=\(good)", "\(hop(id: good))&x=1", "https://\(prod)/admin/auth/mcp/app-authorize?x=1&id=\(good)",
                  "\(hop(id: good))#frag", "\(hop(id: good))/", "\(hop(id: good))\n", " \(hop(id: good))", "\(hop(id: good)) ",
                  "\(hop(id: good))\u{0}", "\(hop(id: good))%0a", "https://\(prod)/admin/auth/mcp/app-authorize?ID=\(good)",
                  "https://\(prod)/admin/auth/mcp/app-authorize?id==\(good)"] {
            XCTAssertFalse(connector(u), u.debugDescription)
        }
    }

    // MARK: channel binding

    func test_connector_hop_letter_is_bound_to_the_device_channel() {
        XCTAssertTrue(connector(hop(id: "gl\(hex)"), channel: "link"))
        XCTAssertTrue(connector(hop(id: "gs\(hex)"), channel: "scheme"))
        XCTAssertFalse(connector(hop(id: "gs\(hex)"), channel: "link"))
        XCTAssertFalse(connector(hop(id: "gi\(hex)"), channel: "link"))
        XCTAssertFalse(connector(hop(id: "gl\(hex)"), channel: "scheme"))
        XCTAssertFalse(connector(hop(id: "gi\(hex)"), channel: "scheme"))
        for ch in ["", "intent", "LINK", "Link", "scheme ", "l", "s", "i", "none"] {
            for letter in ["l", "s", "i"] {
                XCTAssertFalse(connector(hop(id: "g\(letter)\(hex)"), channel: ch), "\(ch) \(letter)")
            }
        }
    }

    // MARK: the one gate

    private let googleProd = "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&redirect_uri=https%3A%2F%2Fai-api-admin.myra.eu%2Fadmin%2Fauth%2Fgoogle%2Fcallback&state=s"
    private let msProd = "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize?client_id=x&redirect_uri=https%3A%2F%2Fai-api-admin.myra.eu%2Fadmin%2Fauth%2Fmicrosoft%2Fcallback&state=s"

    func test_session_kind_routes_provider_and_connector() {
        XCTAssertEqual(AuthURLPolicy.sessionKind(for: googleProd, adminHost: prod, channel: "link"), .provider)
        XCTAssertEqual(AuthURLPolicy.sessionKind(for: msProd, adminHost: prod, channel: "scheme"), .provider)
        XCTAssertEqual(AuthURLPolicy.sessionKind(for: hop(id: "gl\(hex)"), adminHost: prod, channel: "link"), .connector)
        XCTAssertEqual(AuthURLPolicy.sessionKind(for: hop(id: "gs\(hex)"), adminHost: prod, channel: "scheme"), .connector)
    }

    func test_session_kind_refuses_everything_else() {
        XCTAssertNil(AuthURLPolicy.sessionKind(for: hop(id: "gs\(hex)"), adminHost: prod, channel: "link"))
        XCTAssertNil(AuthURLPolicy.sessionKind(for: hop(host: int, id: "gl\(hex)"), adminHost: prod, channel: "link"))
        XCTAssertNil(AuthURLPolicy.sessionKind(for: "https://todoist.com/oauth/authorize?client_id=x&state=y", adminHost: prod, channel: "link"))
        XCTAssertNil(AuthURLPolicy.sessionKind(for: "", adminHost: prod, channel: "link"))
        // provider rule is still bound to the env's redirect_uri
        XCTAssertNil(AuthURLPolicy.sessionKind(for: googleProd, adminHost: int, channel: "link"))
    }

    // MARK: capability advert (AGF-5651)

    func test_oauth_caps_advertise_connector_with_a_connector_capable_cap() {
        XCTAssertEqual(AuthURLPolicy.oauthCapsJS(cap: "link"), ", oauthSession: \"link\", connectorOAuth: true")
        XCTAssertEqual(AuthURLPolicy.oauthCapsJS(cap: "scheme"), ", oauthSession: \"scheme\", connectorOAuth: true")
    }

    func test_oauth_caps_empty_without_a_cap() {
        XCTAssertEqual(AuthURLPolicy.oauthCapsJS(cap: nil), "")
    }

    func test_oauth_caps_do_not_advertise_connector_for_other_caps() {
        XCTAssertEqual(AuthURLPolicy.oauthCapsJS(cap: "bogus"), ", oauthSession: \"bogus\"")
        XCTAssertEqual(AuthURLPolicy.oauthCapsJS(cap: "intent"), ", oauthSession: \"intent\"")
    }

    /// connectorOAuth is advertised exactly when the bridge's gate accepts the connector hop for that cap,
    /// and a connector-capable cap accepts only its own channel letter.
    func test_connector_flag_matches_the_bridge_gate() {
        for cap in ["link", "scheme", "intent", "bogus"] {
            let accepting = ["l", "s", "i"].filter {
                AuthURLPolicy.sessionKind(for: hop(id: "g\($0)\(hex)"), adminHost: prod, channel: cap) == .connector
            }
            let advertised = AuthURLPolicy.oauthCapsJS(cap: cap).contains("connectorOAuth: true")
            XCTAssertEqual(advertised, !accepting.isEmpty, cap)
            if let own = AuthURLPolicy.connectorChannelLetter(for: cap) {
                XCTAssertEqual(accepting, [own], cap)
            } else {
                XCTAssertTrue(accepting.isEmpty, cap)
            }
        }
    }

    // MARK: provider rule regression

    func test_provider_rule_unchanged() {
        XCTAssertTrue(AuthURLPolicy.isAllowedAuthorizeURL(googleProd, adminHost: prod))
        XCTAssertTrue(AuthURLPolicy.isAllowedAuthorizeURL(msProd, adminHost: prod))
        XCTAssertFalse(AuthURLPolicy.isAllowedAuthorizeURL(googleProd, adminHost: int))
        XCTAssertFalse(AuthURLPolicy.isAllowedAuthorizeURL(googleProd.replacingOccurrences(of: "google%2Fcallback", with: "microsoft%2Fcallback"), adminHost: prod))
        XCTAssertFalse(AuthURLPolicy.isAllowedAuthorizeURL(googleProd + "&redirect_uri=x", adminHost: prod))
        XCTAssertFalse(AuthURLPolicy.isAllowedAuthorizeURL(googleProd + "#f", adminHost: prod))
        XCTAssertFalse(AuthURLPolicy.isAllowedAuthorizeURL("https://evil.example/o/oauth2/v2/auth?redirect_uri=https%3A%2F%2Fai-api-admin.myra.eu%2Fadmin%2Fauth%2Fgoogle%2Fcallback", adminHost: prod))
    }

    func test_admin_host_comes_from_the_navigation_policy_table() {
        XCTAssertEqual(AuthURLPolicy.adminHost(forSPAHost: "ai.myra.eu"), prod)
        XCTAssertEqual(AuthURLPolicy.adminHost(forSPAHost: "AI-INT.myra.eu"), int)
        XCTAssertNil(AuthURLPolicy.adminHost(forSPAHost: "evil.example"))
        XCTAssertNil(AuthURLPolicy.adminHost(forSPAHost: nil))
    }

    // MARK: connector-shaped callbacks (completionURL, unchanged)

    private func completion(_ s: String, spa: String = "ai.myra.eu") -> String? {
        URL(string: s).flatMap { AuthURLPolicy.completionURL(for: $0, spaHost: spa) }?.absoluteString
    }

    func test_completion_accepts_connector_returns() {
        let code = String(repeating: "ab", count: 32)   // 64 hex
        XCTAssertEqual(completion("https://ai.myra.eu/auth/app-complete#code=\(code)"), "https://ai.myra.eu/auth/app-complete#code=\(code)")
        XCTAssertEqual(completion("https://ai.myra.eu/auth/app-complete#error=try_again&page=connectors"),
                       "https://ai.myra.eu/auth/app-complete#error=try_again&page=connectors")
        XCTAssertEqual(completion("myraai://oauth?code=\(code)"), "https://ai.myra.eu/auth/app-complete#code=\(code)")
        XCTAssertEqual(completion("myraai://oauth?error=unsupported&page=connectors"),
                       "https://ai.myra.eu/auth/app-complete#error=unsupported&page=connectors")
        XCTAssertEqual(completion("myraai://oauth?error=try_again&page=connectors", spa: "ai-int.myra.eu"),
                       "https://ai-int.myra.eu/auth/app-complete#error=try_again&page=connectors")
    }

    func test_completion_rejects_off_shape_callbacks() {
        for s in ["https://evil.example/auth/app-complete#code=x", "https://ai.myra.eu/auth/other#code=x",
                  "https://ai-int.myra.eu/auth/app-complete#code=x", "https://ai.myra.eu:8443/auth/app-complete#code=x",
                  "http://ai.myra.eu/auth/app-complete#code=x", "myraai://oauth?error=x#y", "myraai://other?code=x",
                  "myraai://oauth/x?code=x", "myraai://oauth?code=a%20b", "myraai://oauth?code=a.b", "myraai://oauth",
                  "other://oauth?code=x"] {
            XCTAssertNil(completion(s), s)
        }
        XCTAssertNil(completion("myraai://oauth?code=" + String(repeating: "a", count: 1025)))
    }

    func test_app_complete_path_detection_unchanged() {
        for p in ["/auth/app-complete", "/AUTH/App-Complete/", "/auth//app-complete", "/auth/./app-complete",
                  "/x/../auth/app-complete", "/auth/app%2Dcomplete", "\\auth\\app-complete"] {
            XCTAssertTrue(AuthURLPolicy.isAppCompletePath(p), p)
        }
        for p in ["/auth/app-complete/x", "/auth", "/", "/connectors"] {
            XCTAssertFalse(AuthURLPolicy.isAppCompletePath(p), p)
        }
    }
}
