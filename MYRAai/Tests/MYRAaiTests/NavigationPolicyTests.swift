import XCTest

/// AGF-3766 — unit matrix of NavigationPolicy.decide (the source file is compiled into this logic-test bundle;
/// no app host, no simulator UI). The on-device proof is NavigationGuards (UI tests).
final class NavigationPolicyTests: XCTestCase {

    private func d(_ s: String?, _ t: NavigationPolicy.Target) -> NavigationPolicy.Decision {
        NavigationPolicy.decide(url: s.flatMap { URL(string: $0) }, target: t)
    }

    private let sandboxed = NavigationPolicy.Target.subframe(opaqueOrigin: true)
    private let framed = NavigationPolicy.Target.subframe(opaqueOrigin: false)

    // MARK: a subframe is never handed to the system

    func test_subframe_never_opens_externally() {
        let urls = ["https://exfil.example/?d=x", "http://exfil.example/", "https://ai.myra.eu/x",
                    "mailto:a@b.c", "tel:+1", "sms:+1&body=x", "maps:q=x", "facetime:+1",
                    "whatsapp://send?text=x", "intent://x#Intent;scheme=https;end", "itms-services://?action=x",
                    "myraai://oauth?code=x", "javascript:alert(1)", "file:///etc/hosts", "foo:bar", "HTTPS://EXFIL.EXAMPLE/"]
        for u in urls {
            XCTAssertNotEqual(d(u, sandboxed), .openExternally, u)
            XCTAssertNotEqual(d(u, framed), .openExternally, u)
        }
    }

    func test_sandboxed_preview_cannot_navigate_to_the_network() {
        XCTAssertEqual(d("https://exfil.example/?d=x", sandboxed), .cancel)
        XCTAssertEqual(d("https://ai.myra.eu/easy", sandboxed), .cancel)      // owned too: a preview never navigates
        XCTAssertEqual(d("http://exfil.example/", sandboxed), .cancel)
    }

    func test_subframe_local_documents_load() {
        for u in ["about:srcdoc", "about:blank", "blob:https://ai.myra.eu/1234", "data:text/html,x"] {
            XCTAssertEqual(d(u, sandboxed), .allow, u)
            XCTAssertEqual(d(u, framed), .allow, u)
        }
    }

    func test_non_sandboxed_subframe_https_loads_in_place() {
        // The captcha's challenge frame, the admin-host PDF frame, an owned frame's redirect: the embedder's CSP decides.
        XCTAssertEqual(d("https://cdn.eu-captcha.eu/check.html#host=ai.myra.eu", framed), .allow)
        XCTAssertEqual(d("https://ai-api-admin.myra.eu/admin/files/x", framed), .allow)
        XCTAssertEqual(d("https://ai-docs.myra.eu/", framed), .allow)
    }

    func test_subframe_other_schemes_are_cancelled() {
        for u in ["mailto:a@b.c", "sms:+1", "whatsapp://send?text=x", "intent://x#Intent;end", "foo:bar",
                  "javascript:alert(1)", "file:///etc/hosts", "https:///nohost"] {
            XCTAssertEqual(d(u, framed), .cancel, u)
            XCTAssertEqual(d(u, sandboxed), .cancel, u)
        }
    }

    // MARK: main frame / new window — unchanged

    func test_main_frame_owned_loads_in_place() {
        for host in ["ai.myra.eu", "AI.MYRA.EU", "ai-int.myra.eu", "ai-api-admin.myra.eu", "x.ai.myra.eu"] {
            XCTAssertEqual(d("https://\(host)/easy", .mainFrame), .allow, host)
            XCTAssertEqual(d("https://\(host)/easy", .newWindow), .allow, host)
        }
    }

    func test_main_frame_lookalikes_are_not_owned() {
        for u in ["https://evilai.myra.eu/", "https://ai.myra.eu.evil.example/", "https://myra.eu/", "https://notai.myra.eu.example/"] {
            XCTAssertEqual(d(u, .mainFrame), .openExternally, u)
        }
    }

    func test_main_frame_user_links_hand_off() {
        XCTAssertEqual(d("https://www.myrasecurity.com/", .newWindow), .openExternally)
        XCTAssertEqual(d("https://exfil.example/", .mainFrame), .openExternally)
        for u in ["mailto:a@b.c", "tel:+1", "sms:+1", "maps:q=x", "facetime:+1", "facetime-audio:+1", "MAILTO:a@b.c"] {
            XCTAssertEqual(d(u, .mainFrame), .openExternally, u)
        }
    }

    func test_main_frame_hostless_stays() {
        XCTAssertEqual(d("about:blank", .mainFrame), .allow)
        XCTAssertEqual(d("blob:https://ai.myra.eu/1", .newWindow), .cancel)   // no second web view to open it in
        XCTAssertEqual(d("about:blank", .newWindow), .cancel)
        XCTAssertEqual(d(nil, .mainFrame), .allow)
        XCTAssertEqual(d(nil, sandboxed), .allow)
    }

    // MARK: property — random / malformed URLs (seeded, reproducible)

    /// SplitMix64 — a tiny deterministic generator so a failure replays (seed in the message).
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    func test_fuzz_subframe_never_opens_externally() {
        let seed: UInt64 = 0x3766
        var rng = SeededRNG(state: seed)
        let alphabet = Array("abcXYZ019-._~:/?#[]@!$&'()*+,;=% \t\"<>\\^`{|}é万")
        let schemes = ["https", "http", "HTTPS", "whatsapp", "intent", "mailto", "tel", "sms", "about", "blob",
                       "data", "javascript", "file", "myraai", ""]
        for i in 0..<5000 {
            let len = Int.random(in: 0..<40, using: &rng)
            let tail = String((0..<len).map { _ in alphabet.randomElement(using: &rng)! })
            let scheme = schemes.randomElement(using: &rng)!
            let raw = Bool.random(using: &rng) ? "\(scheme)://\(tail)" : "\(scheme):\(tail)"
            let url = URL(string: raw)
            for opaque in [true, false] {
                XCTAssertNotEqual(NavigationPolicy.decide(url: url, target: .subframe(opaqueOrigin: opaque)),
                                  .openExternally, "seed \(seed) #\(i): \(raw)")
            }
            // A sandboxed frame never loads a network URL, and only local documents load in it at all.
            let sandboxed = NavigationPolicy.decide(url: url, target: .subframe(opaqueOrigin: true))
            if sandboxed == .allow, let url {
                XCTAssertTrue(["about", "blob", "data"].contains((url.scheme ?? "").lowercased()),
                              "seed \(seed) #\(i): sandboxed frame allowed \(raw)")
            }
        }
    }

    func test_main_frame_owned_host_only_over_web() {
        for u in ["intent://ai.myra.eu/x", "foo://ai.myra.eu/x", "javascript://ai.myra.eu/%0Aalert(1)"] {
            XCTAssertEqual(d(u, .mainFrame), .openExternally, u)
            XCTAssertEqual(d(u, .newWindow), .openExternally, u)
        }
        XCTAssertEqual(d("http://ai.myra.eu/x", .mainFrame), .allow)
    }

    // MARK: AGF-3778 — who the native bridge answers

    func test_bridge_answers_only_the_app_top_level_page() {
        XCTAssertTrue(NavigationPolicy.isAppBridgeFrame(isMainFrame: true, protocol: "https", host: "ai.myra.eu", port: 0))
        XCTAssertTrue(NavigationPolicy.isAppBridgeFrame(isMainFrame: true, protocol: "https", host: "ai-int.myra.eu", port: 0))
        XCTAssertTrue(NavigationPolicy.isAppBridgeFrame(isMainFrame: true, protocol: "HTTPS", host: "AI.MYRA.EU", port: 0))
        // a subframe of the app's own origin (e.g. the blob PDF frame), a sandboxed preview (opaque origin)
        XCTAssertFalse(NavigationPolicy.isAppBridgeFrame(isMainFrame: false, protocol: "https", host: "ai.myra.eu", port: 0))
        XCTAssertFalse(NavigationPolicy.isAppBridgeFrame(isMainFrame: false, protocol: "", host: "", port: 0))
        XCTAssertFalse(NavigationPolicy.isAppBridgeFrame(isMainFrame: true, protocol: "", host: "", port: 0))
        // other owned hosts are not the SPA; wrong scheme / port; look-alikes
        for host in ["ai-api.myra.eu", "ai-api-admin.myra.eu", "docs.ai.myra.eu", "evilai.myra.eu", "ai.myra.eu.evil.example", "myra.eu"] {
            XCTAssertFalse(NavigationPolicy.isAppBridgeFrame(isMainFrame: true, protocol: "https", host: host, port: 0), host)
        }
        XCTAssertFalse(NavigationPolicy.isAppBridgeFrame(isMainFrame: true, protocol: "http", host: "ai.myra.eu", port: 0))
        XCTAssertFalse(NavigationPolicy.isAppBridgeFrame(isMainFrame: true, protocol: "https", host: "ai.myra.eu", port: 8443))
        XCTAssertFalse(NavigationPolicy.isAppBridgeFrame(isMainFrame: true, protocol: "file", host: "", port: 0))
    }

    // MARK: AGF-4244 — tool-approval push tap target

    private let rid = "0b1f6c2e-9d4a-4e0b-8c1d-5a7e3f2b9c10"

    private func push(_ id: Any?, kind: Any? = "tool_approval", host: String? = "ai.myra.eu") -> URL? {
        var ui: [AnyHashable: Any] = [:]
        if let kind { ui["kind"] = kind }
        if let id { ui["review_id"] = id }
        return NavigationPolicy.pushTargetURL(userInfo: ui, spaHost: host)
    }

    func test_push_valid_id_builds_the_approval_card_url() {
        XCTAssertEqual(push(rid)?.absoluteString, "https://ai.myra.eu/approvals/tools/\(rid)")
        XCTAssertEqual(push(rid, host: "ai-int.myra.eu")?.absoluteString, "https://ai-int.myra.eu/approvals/tools/\(rid)")
        XCTAssertEqual(push(rid, host: "AI-INT.myra.eu")?.host, "ai-int.myra.eu")
    }

    func test_push_unknown_or_missing_host_falls_back_to_prod() {
        for h in [nil, "", "evil.example", "ai.myra.eu.evil.example", "ai-api-admin.myra.eu", "docs.ai.myra.eu"] as [String?] {
            XCTAssertEqual(push(rid, host: h)?.absoluteString, "https://ai.myra.eu/approvals/tools/\(rid)", h ?? "nil")
        }
    }

    func test_push_malformed_review_id_has_no_target() {
        let bad = ["\(rid)\n", " \(rid)", "\(rid) ", rid.uppercased(), "", "../x", "\(rid)/x", "\(rid)?a", "\(rid)#a",
                   "%2F", "\(rid)0", "\(rid)00000", String(rid.dropLast()), "\(rid.dropLast())b\u{20DD}",
                   rid.replacingOccurrences(of: "-", with: ""), "g\(rid.dropFirst())", "\u{FF10}\(rid.dropFirst())"]
        for id in bad {
            XCTAssertNil(push(id), id.debugDescription)
        }
    }

    func test_push_absent_or_wrongly_typed_fields_have_no_target() {
        XCTAssertNil(push(nil))                                  // kind present, review_id absent
        XCTAssertNil(push(rid, kind: nil))                       // kind absent, valid id
        XCTAssertNil(push(rid, kind: "chat_reply"))              // another kind never routes here
        XCTAssertNil(push(rid, kind: "TOOL_APPROVAL"))
        XCTAssertNil(push(NSNumber(value: 42)))                  // not a string
        XCTAssertNil(push(["x"]))
        XCTAssertNil(push(rid, kind: 7))
        XCTAssertNil(NavigationPolicy.pushTargetURL(userInfo: [:], spaHost: "ai.myra.eu"))
    }

    func test_push_path_in_payload_is_ignored() {
        let ui: [AnyHashable: Any] = ["kind": "tool_approval", "review_id": rid, "path": "https://evil.example/x"]
        XCTAssertEqual(NavigationPolicy.pushTargetURL(userInfo: ui, spaHost: nil)?.absoluteString,
                       "https://ai.myra.eu/approvals/tools/\(rid)")
    }

    // MARK: AGF-3621 — isAppPage (the sender check of the sign-in bridge and of downloads)

    private func page(main: Bool = true, proto: String = "https", host: String = "ai.myra.eu", port: Int = 0,
                      web: String? = "ai.myra.eu") -> Bool {
        NavigationPolicy.isAppPage(isMainFrame: main, protocol: proto, host: host, port: port, webViewHost: web)
    }

    func test_isAppPage_accepts_only_the_shown_spa_main_frame() {
        XCTAssertTrue(page())
        XCTAssertTrue(page(host: "AI.MYRA.EU", web: "ai.myra.eu"))
        XCTAssertTrue(page(proto: "HTTPS"))
        XCTAssertTrue(page(host: "ai-int.myra.eu", web: "ai-int.myra.eu"))
    }

    func test_isAppPage_rejects_everything_else() {
        XCTAssertFalse(page(host: "ai.myra.eu", web: "ai-int.myra.eu"))   // host mismatch
        XCTAssertFalse(page(web: nil))                                    // no page shown
        XCTAssertFalse(page(main: false))                                 // subframe
        XCTAssertFalse(page(proto: "http"))
        XCTAssertFalse(page(port: 8443))
        XCTAssertFalse(page(proto: "", host: "", web: ""))                // opaque origin (sandboxed preview)
        XCTAssertFalse(page(host: "evil.example", web: "evil.example"))   // not an SPA host
        XCTAssertFalse(page(host: "ai-api-admin.myra.eu", web: "ai-api-admin.myra.eu"))
    }
}
