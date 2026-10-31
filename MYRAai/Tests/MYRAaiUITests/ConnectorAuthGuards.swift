import XCTest

/// AGF-5511 — the connector OAuth hand-off goes through the native auth session, and only for the owned hop.
///
/// The SPA asks the shell for an `ASWebAuthenticationSession` with `openAuthSession` (AGF-3462). The bridge now
/// accepts two URL shapes: a provider authorize URL (sign-in) and the owned connector start hop
/// `https://<admin host>/admin/auth/mcp/app-authorize?id=g<l|s><32 hex>` (AuthURLPolicy.sessionKind). Everything
/// else must be dropped without a session. The decision table is unit tested (AuthURLPolicyTests); these guards
/// prove the wiring in the real app: the probe page (DEBUG hook `-MyraUITestHTML`, base https://ai.myra.eu/) posts
/// to the real message handler and the app's own decision lines (`AUTH …`, written into the probe page; the URL
/// itself is never logged) are asserted.
///
/// The owned-hop test cannot rely on the remote end (the id is not a real session): it asserts the native
/// decision (`AUTH accepted connector`) and that the app, the probe page and the system browser are undisturbed
/// whichever way the session then ends (cancelled by the test, failed to start, or errored).
final class ConnectorAuthGuards: XCTestCase {

    private var safari: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.mobilesafari") }
    private let hex32 = "0123456789abcdef0123456789abcdef"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        safari.terminate()
    }

    override func tearDown() {
        XCUIApplication().terminate()
        super.tearDown()
    }

    // MARK: - The owned hop is accepted

    func test_owned_connector_start_opens_auth_session_and_cancel_stays() throws {
        // `L` is the page's own channel letter, from the capability the shell advertises.
        let app = launchProbe(body: "\"https://ai-api-admin.myra.eu/admin/auth/mcp/app-authorize?id=g\" + L + \"\(hex32)\"")
        try XCTSkipIf(capability(app) == nil, "this device advertises no oauthSession capability (iPad below iOS 17.4)")
        send(app)
        XCTAssertTrue(waitForNavlog(app, containing: "AUTH accepted connector", timeout: 10),
                      "the owned connector hop was not accepted — navlog: \(readNavlog(app))")
        // Branch B: no session opened. Branch A: opened (see settleOpenedSession).
        let opened = waitForNavlog(app, containing: "AUTH opened", timeout: 10)
        if opened {
            try settleOpenedSession(app)
        } else {
            let failed = waitForNavlog(app, containing: "AUTH start-failed", timeout: 5)
                || waitForNavlog(app, containing: "AUTH done error", timeout: 5)
            logProbeLine(tag: "CONNECTORAUTH", "branch=not-opened outcome=\(failed ? "start-failed-or-error" : "none")")
            XCTAssertTrue(failed, "accepted but neither opened nor start-failed / done error — navlog: \(readNavlog(app))")
            XCTAssertFalse(readNavlog(app).contains("AUTH opened"), "a session opened late — navlog: \(readNavlog(app))")
        }
        logProbeLine(tag: "CONNECTORAUTH", "navlog: \(readNavlog(app))")
        capture(app, "connector_accepted")
        let navlog = readNavlog(app)
        XCTAssertFalse(navlog.contains("app-complete"), "a completion page was loaded without a result — navlog: \(navlog)")
        XCTAssertFalse(navlog.contains("AUTH done loaded"), "the session reported a loaded completion — navlog: \(navlog)")
        XCTAssertTrue(app.webViews.firstMatch.buttons["connector-send"].exists, "the probe page is no longer shown")
        XCTAssertNotEqual(safari.state, .runningForeground, "the connector hand-off reached the system browser")
    }

    // MARK: - The connector capability (AGF-5651)

    /// The real injected `window.__myraNativeCaps` carries `connectorOAuth` exactly when `oauthSession` is set, as the
    /// boolean `true` (the page logs `typeof` too, so the string "true" cannot pass). Never skipped. A device with no
    /// cap (iPad below iOS 17.4; the nav-guard simulators are newer, so CI runs the cap branch) must not advertise it.
    func test_connector_capability_matches_oauth_session() {
        let app = launchProbe(body: "\"\"")
        let lines = readNavlog(app).split(separator: "\n").map(String.init)
        let conn = lines.filter { $0.hasPrefix("CAPCONN ") }
        if capability(app) != nil {
            XCTAssertEqual(conn, ["CAPCONN boolean true"], "navlog: \(readNavlog(app))")
        } else {
            XCTAssertEqual(conn, ["CAPCONN undefined undefined"], "navlog: \(readNavlog(app))")
        }
    }

    // MARK: - Everything else is refused

    func test_provider_url_is_refused() throws {
        try assertRefused("https://todoist.com/oauth/authorize?client_id=x&state=y")
    }

    func test_other_env_hop_is_refused() throws {
        // The int admin host from the prod page.
        try assertRefused(body: "\"https://ai-api-admin-int.myra.eu/admin/auth/mcp/app-authorize?id=g\" + L + \"\(hex32)\"")
    }

    func test_wrong_channel_hop_is_refused() throws {
        // `i` (intent) is Android only; deliberately NOT the page's `L`, and no iOS device advertises `gi`.
        try assertRefused("https://ai-api-admin.myra.eu/admin/auth/mcp/app-authorize?id=gi\(hex32)")
    }

    func test_malformed_id_is_refused() throws {
        try assertRefused(body: "\"https://ai-api-admin.myra.eu/admin/auth/mcp/app-authorize?id=g\" + L + \"\(hex32.uppercased())\"")
    }

    func test_non_string_body_is_refused() throws {
        try assertRefused(body: "{url: \"https://ai-api-admin.myra.eu/admin/auth/mcp/app-authorize?id=g\" + L + \"\(hex32)\"}")
    }

    // MARK: - Engine

    private func capture(_ app: XCUIApplication, _ name: String) { attachScreenshot(prefix: "connectorauth", name) }

    private func assertRefused(_ url: String) throws {
        try assertRefused(body: "\"\(url)\"")
    }

    /// The body is refused at the URL gate: exactly `AUTH refused url` (not cap / frame / webview / host / pending), and
    /// nothing is accepted or opened. A device with no capability is skipped, like the accepted-hop test.
    private func assertRefused(body: String) throws {
        let app = launchProbe(body: body)
        try XCTSkipIf(capability(app) == nil, "this device advertises no oauthSession capability (iPad below iOS 17.4)")
        send(app)
        XCTAssertTrue(waitForNavlog(app, containing: "AUTH refused url", timeout: 10),
                      "the request was not refused at the URL gate — navlog: \(readNavlog(app))")
        capture(app, "refused")
        assertNoSession(app)
    }

    private func assertNoSession(_ app: XCUIApplication) {
        // Give a (wrong) session time to show itself: a consent alert would appear on the springboard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 5), "a refused request raised a system alert")
        let navlog = readNavlog(app)
        XCTAssertFalse(navlog.contains("AUTH accepted"), "a refused request was accepted — navlog: \(navlog)")
        XCTAssertFalse(navlog.contains("AUTH opened"), "a refused request opened a session — navlog: \(navlog)")
        XCTAssertNotEqual(safari.state, .runningForeground, "a refused request reached the system browser")
    }

    private func launchProbe(body: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-MyraUITestHTML", "-MyraUITestSuppressPushPrompt",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["MYRA_UITEST_HTML"] = probePage.replacingOccurrences(of: "__BODY__", with: body)
        app.launch()
        XCTAssertTrue(waitForNavlog(app, containing: "PAGE connector", timeout: 30),
                      "the probe page did not load — is the -MyraUITestHTML hook in this (Debug) build?")
        return app
    }

    /// The `oauthSession` value the page sees ("link" | "scheme"), or nil when the device has none.
    private func capability(_ app: XCUIApplication) -> String? {
        let log = readNavlog(app)
        if log.contains("CAP link") { return "link" }
        if log.contains("CAP scheme") { return "scheme" }
        return nil
    }

    /// Taps the page's button, which posts the launch-time body to `openAuthSession`.
    private func send(_ app: XCUIApplication) {
        let button = app.webViews.firstMatch.buttons["connector-send"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no send button in the probe page")
        button.tap()
        XCTAssertTrue(waitForNavlog(app, containing: "SENT", timeout: 5),
                      "the tap did not reach the page (no SENT line) — navlog: \(readNavlog(app))")
    }

    /// Taps the consent alert's ("Wants to Use … to Sign In") or the sheet's Cancel, if one is showing right now.
    /// Returns whether a button was tapped.
    private func cancelSessionSheet() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alertCancel = springboard.alerts.buttons["Cancel"]
        if alertCancel.exists { alertCancel.tap(); return true }
        let sheetCancel = safari.buttons["Cancel"]
        if sheetCancel.exists { sheetCancel.tap(); return true }
        return false
    }

    /// Branch A: `AUTH opened`. Either the system already ended the session itself (outcome "system-ended": the
    /// unsigned CI simulator has no webcredentials entitlement, so it cancels without consent UI) or a Cancel UI
    /// shows and is tapped (outcome "user-cancel"). Both must end in `AUTH done cancelled`; anything else fails.
    private func settleOpenedSession(_ app: XCUIApplication) throws {
        var outcome = "none"
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if readNavlog(app).contains("AUTH done") { outcome = "system-ended"; break }
            if cancelSessionSheet() { outcome = "user-cancel"; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        logProbeLine(tag: "CONNECTORAUTH", "branch=opened outcome=\(outcome)")
        if outcome == "none" {
            capture(app, "opened_stuck")
            XCTFail("opened branch: session neither cancellable nor ended — navlog: \(readNavlog(app))")
            return
        }
        XCTAssertTrue(waitForNavlog(app, containing: "AUTH done cancelled", timeout: 15),
                      "opened branch (\(outcome)): no `AUTH done cancelled` — navlog: \(readNavlog(app))")
    }

    private let probePage = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <style>#navlog{margin:0;padding:8px;white-space:pre-wrap;font:12px monospace}button{font-size:18px;margin:4px;padding:8px}body{padding-top:140px}</style></head>
    <body>
    <button id="connector-send" aria-label="connector-send">connector-send</button>
    <pre id="navlog" aria-label="navlog">NAVLOG</pre><script>
    (function () {
      var log = document.getElementById("navlog");
      window.__navlog = function (line) { log.textContent += "\\n" + line; };
      var caps = window.__myraNativeCaps || {};
      window.__navlog("PAGE connector");
      window.__navlog("CAP " + (caps.oauthSession || "none"));
      window.__navlog("CAPCONN " + typeof caps.connectorOAuth + " " + caps.connectorOAuth);
      var L = caps.oauthSession === "link" ? "l" : "s";
      document.getElementById("connector-send").onclick = function () {
        window.__navlog("SENT");
        window.webkit.messageHandlers.openAuthSession.postMessage(__BODY__);
      };
    })();
    </script></body></html>
    """
}
