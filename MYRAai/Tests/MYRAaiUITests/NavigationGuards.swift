import XCTest
import UIKit

/// AGF-3766 — a preview's navigation never leaves the app.
///
/// Every sandboxed preview (artifact / React / MCP viewer) renders one frame below the navigation-fenced host
/// document (AGF-3758, `sandboxHost.html`). The app's navigation policy hook runs BEFORE WebKit loads the
/// request, so a shell that hands a subframe's navigation to the system would leak it to Safari / another app
/// before the fence applies. These guards load a probe page into the app (DEBUG hook `-MyraUITestHTML`) that
/// frames a preview exactly like SandboxFrame does — `fenced` (below the REAL host document) and `direct` (no
/// fence: the shell's own policy alone) — and let the preview try one navigation vector per launch.
///
/// Detection does not trust the code under test: the system browser is observed directly (Safari reaching the
/// foreground, our app leaving it). The app's own decision log (`NAV … -> allow|cancel|external`, written into
/// the probe page in probe mode) is asserted too and is what the screenshot shows.
///
/// Positive control (`test_app_link_tap_opens_system_browser`): a link the APP renders, tapped by the user,
/// still opens Safari — proves the detector sees a real hand-off (the preview tests are not vacuous).
///
/// Hermetic: no login, no SPA; the captcha check asserts only the native decision for the frame, not the remote
/// page. One screenshot per test is attached to the result (the nav-guard workflow exports them).
final class NavigationGuards: XCTestCase {

    /// A FRESH proxy per query: a proxy that terminated Safari keeps tracking the dead process and never reports
    /// the Safari that a hand-off launches afterwards (measured: Safari on screen, state stayed "not running").
    private var safari: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.mobilesafari") }
    /// How long a vector gets to reach the system browser (vectors fire ~0.4 s after the preview loads).
    private let observeSeconds: TimeInterval = 5
    /// Per run: every bridge sentinel in the probe page carries it.
    private let nonce = String(UUID().uuidString.prefix(8))

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // A previous (leaking) run may have left Safari in front.
        safari.terminate()
    }

    // MARK: - Preview vectors, fenced (the product's structure)

    func test_fenced_self() throws { try assertPreviewStaysInApp("self", "fenced") }
    func test_fenced_replace() throws { try assertPreviewStaysInApp("replace", "fenced") }
    func test_fenced_top() throws { try assertPreviewStaysInApp("top", "fenced") }
    func test_fenced_open() throws { try assertPreviewStaysInApp("open", "fenced") }
    func test_fenced_blank() throws { try assertPreviewStaysInApp("blank", "fenced") }
    func test_fenced_form() throws { try assertPreviewStaysInApp("form", "fenced") }
    func test_fenced_meta() throws { try assertPreviewStaysInApp("meta", "fenced") }
    func test_fenced_scheme() throws { try assertPreviewStaysInApp("scheme", "fenced") }
    func test_fenced_custom() throws { try assertPreviewStaysInApp("custom", "fenced") }
    func test_fenced_intent() throws { try assertPreviewStaysInApp("intent", "fenced") }
    func test_fenced_tap() throws { try assertPreviewStaysInApp("tap", "fenced") }
    func test_fenced_tapblank() throws { try assertPreviewStaysInApp("tapblank", "fenced") }

    // MARK: - Preview vectors, direct (no fence — the shell's policy on its own)

    func test_direct_self() throws { try assertPreviewStaysInApp("self", "direct") }
    func test_direct_replace() throws { try assertPreviewStaysInApp("replace", "direct") }
    func test_direct_top() throws { try assertPreviewStaysInApp("top", "direct") }
    func test_direct_open() throws { try assertPreviewStaysInApp("open", "direct") }
    func test_direct_blank() throws { try assertPreviewStaysInApp("blank", "direct") }
    func test_direct_form() throws { try assertPreviewStaysInApp("form", "direct") }
    func test_direct_meta() throws { try assertPreviewStaysInApp("meta", "direct") }
    func test_direct_scheme() throws { try assertPreviewStaysInApp("scheme", "direct") }
    func test_direct_custom() throws { try assertPreviewStaysInApp("custom", "direct") }
    func test_direct_intent() throws { try assertPreviewStaysInApp("intent", "direct") }
    func test_direct_tap() throws { try assertPreviewStaysInApp("tap", "direct") }
    func test_direct_tapblank() throws { try assertPreviewStaysInApp("tapblank", "direct") }

    // MARK: - Controls

    /// Positive control: the user taps a target=_blank link the app page itself renders → Safari opens.
    func test_app_link_tap_opens_system_browser() throws {
        let app = launchProbe(vector: "apptap", variant: "fenced")
        let link = app.links["agf3766 app link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), "the app page's link did not render")
        link.tap()
        // Safari in front OR our app pushed out of it — measured (AGF-3778 RED run): with Safari on its first-launch
        // "Start Page" sheet its proxy kept reporting "not in the foreground" while the screenshot showed it there.
        let reached = observeSystemBrowser(app, seconds: 10)
        capture(app, "apptap")
        let navlog = foregroundNavlog(app)
        log("apptap safariForeground=\(reached) navlog=\(navlog)")
        XCTAssertTrue(reached, "a user tap on a link the app renders must still open the system browser")
        XCTAssertTrue(navlog.contains("EXTERNAL https://exfil.example/agf3766?d=SENTINEL-apptap"),
                      "the app's own link was not handed off by the policy — navlog: \(navlog)")
        XCTAssertEqual(navlog.components(separatedBy: "EXTERNAL ").count - 1, 1,
                       "the app's own link must be handed off exactly once — navlog: \(navlog)")
    }

    /// Control: the user taps a mailto: link the app page renders → the policy hands it to the system (the
    /// simulator has no mail app, so only the decision is observable here).
    func test_app_mailto_tap_is_handed_off() throws {
        let app = launchProbe(vector: "appmailto", variant: "fenced")
        let link = app.links["agf3766 app mail link"]
        XCTAssertTrue(link.waitForExistence(timeout: 15), "the app page's mail link did not render")
        link.tap()
        _ = waitForNavlog(app, containing: "mailto:", timeout: 10)
        capture(app, "appmailto")
        let navlog = readNavlog(app)
        log("appmailto navlog=\(navlog)")
        XCTAssertTrue(navlog.contains("EXTERNAL mailto:"),
                      "the app's own mailto link was not handed off — navlog: \(navlog)")
    }

    /// The sign-up captcha's challenge frame is a third-party subframe the app must render IN the frame —
    /// never in the system browser.
    func test_captcha_frame_renders_in_app() throws {
        let app = launchProbe(vector: "captcha", variant: "fenced")
        let observed = observeSystemBrowser(app)
        capture(app, "captcha")
        let navlog = foregroundNavlog(app)
        let leaked = observed || handedOff(navlog)
        log("captcha leaked=\(leaked) navlog=\(navlog)")
        XCTAssertFalse(leaked, "the captcha frame was handed to the system browser — navlog: \(navlog)")
        let captchaAllowed = navlog.components(separatedBy: "\n").contains {
            $0.contains("url=https://cdn.eu-captcha.eu/") && $0.hasSuffix("-> allow")
        }
        XCTAssertTrue(captchaAllowed,
                      "the captcha frame was not allowed to load in place — navlog: \(navlog)")
        XCTAssertFalse(navlog.contains("-> external"), "a hand-off was decided — navlog: \(navlog)")
    }

    // MARK: - AGF-3778: the native bridge answers only the app's own top-level page
    //
    // Observed WITHOUT the bridge code: the share sheet (UIActivityViewController) on screen, and the system
    // pasteboard's changeCount (reading the count never triggers the paste prompt, reading the content would).

    func test_fenced_preview_gets_no_native_bridge() throws { try assertBridgeRefused("bridgeall", "fenced", caller: "PREVIEW called preview") }
    func test_direct_preview_gets_no_native_bridge() throws { try assertBridgeRefused("bridgeall", "direct", caller: "PREVIEW called preview") }
    /// A SAME-ORIGIN child of the app page (an unsandboxed srcdoc frame, like the blob PDF frame): not the
    /// top-level page, so the native side must refuse it — this exercises the frameInfo check itself.
    func test_app_child_frame_gets_no_native_bridge() throws {
        try assertBridgeRefused("appchild", "fenced", caller: "CHILD called child",
                                // Non-vacuity: the child DOES see the message handlers (WebKit exposes them to every
                                // frame), so its calls reach the native side and the frame check must refuse them.
                                mustSee: "CHILD surface Android=undefined webkit=object")
    }

    /// Positive control: the app's own top-level page still gets every function (share sheet, clipboard).
    func test_app_page_bridge_still_works() throws {
        let before = UIPasteboard.general.changeCount
        let app = launchProbe(vector: "appbridge", variant: "fenced")
        XCTAssertTrue(waitForNavlog(app, containing: "APP called app", timeout: 15), "the app page never ran its bridge calls")
        let sheet = waitForShareSheet(app, timeout: 10)
        capture(app, "appbridge")
        let after = UIPasteboard.general.changeCount
        log("appbridge shareSheet=\(sheet) pasteboard \(before)->\(after) navlog=\(readNavlog(app))")
        XCTAssertTrue(sheet, "the app page's share call no longer opens the share sheet")
        XCTAssertGreaterThan(after, before, "the app page's copyToClipboard no longer reaches the pasteboard")
    }

    private func assertBridgeRefused(_ vector: String, _ variant: String, caller: String, mustSee: String? = nil) throws {
        let before = UIPasteboard.general.changeCount
        let app = launchProbe(vector: vector, variant: variant)
        let label = "\(variant)_\(vector)"
        XCTAssertTrue(waitForNavlog(app, containing: caller, timeout: 15), "\(label): the caller never ran its bridge calls — vacuous")
        let sheet = waitForShareSheet(app, timeout: observeSeconds)
        capture(app, label)
        let after = UIPasteboard.general.changeCount
        let navlog = readNavlog(app)
        log("\(label) shareSheet=\(sheet) pasteboard \(before)->\(after) navlog=\(navlog)")
        if let mustSee {
            XCTAssertTrue(navlog.contains(mustSee), "\(label): the frame never saw the bridge — vacuous. navlog: \(navlog)")
        }
        XCTAssertFalse(sheet, "\(label): a non-top-level frame opened the share sheet through the bridge — navlog: \(navlog)")
        XCTAssertEqual(after, before, "\(label): a non-top-level frame wrote the pasteboard through the bridge — navlog: \(navlog)")
    }

    /// The system share sheet (UIActivityViewController) — matched by the identifiers / labels it exposes. The probe
    /// page has no "Copy" / "Close" control of its own, so those labels can only come from the sheet.
    private func waitForShareSheet(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let candidates = [app.otherElements["ActivityListView"], app.navigationBars["UIActivityContentView"],
                          app.buttons["Copy"], app.cells["Copy"], app.buttons["Close"]]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if candidates.contains(where: { $0.exists }) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return candidates.contains(where: { $0.exists })
    }

    // MARK: - Engine

    private func assertPreviewStaysInApp(_ vector: String, _ variant: String) throws {
        let app = launchProbe(vector: vector, variant: variant)
        let label = "\(variant)_\(vector)"
        // Non-vacuity: the preview document really rendered (it reports through the host / its parent).
        let loaded = waitForNavlog(app, containing: "PREVIEW loaded \(vector)", timeout: 15)
        var tapped = true
        if vector == "tap" || vector == "tapblank" {
            tapPreviewLink(app)
            tapped = waitForNavlog(app, containing: "PREVIEW clicked \(vector)", timeout: 5)
        }
        let observed = observeSystemBrowser(app)
        capture(app, label)
        let navlog = foregroundNavlog(app)
        // A hand-off is either seen (Safari / our app leaving the foreground) or recorded by the app's one
        // hand-off point (EXTERNAL …) — measured: the Safari state alone misses a hand-off made while the test was
        // still waiting for the preview, the screenshot showed Safari all the same.
        let leaked = observed || handedOff(navlog)
        log("\(label) leaked=\(leaked) navlog=\(navlog)")
        XCTAssertTrue(loaded, "\(label): the preview never rendered — the probe is vacuous. navlog: \(navlog)")
        XCTAssertTrue(tapped || leaked, "\(label): the tap never reached the preview link — vacuous. navlog: \(navlog)")
        XCTAssertFalse(leaked, "\(label): the preview's navigation reached the system browser — navlog: \(navlog)")
        XCTAssertFalse(navlog.contains("-> external"),
                       "\(label): the app decided to hand a preview navigation to the system — navlog: \(navlog)")
        // Unfenced, these vectors reach the policy delegate (measured): the sandboxed (opaque-origin) frame's
        // navigation must be CANCELLED there, not loaded in the frame — this pins the opaque-origin detection
        // (WKFrameInfo.securityOrigin of a sandboxed frame has no host) on a real WebKit.
        // App-scheme vectors (scheme / custom / intent): when WebKit asks the delegate at all, the answer is cancel.
        if variant == "direct" && ["scheme", "custom", "intent"].contains(vector) {
            let allowed = navlog.components(separatedBy: "\n").contains {
                $0.contains("SENTINEL-\(vector)") && $0.hasSuffix("-> allow")
            }
            XCTAssertFalse(allowed,
                           "\(label): an app-scheme navigation was allowed — navlog: \(navlog)")
        }
        if variant == "direct" && ["self", "replace", "meta", "tap"].contains(vector) {
            XCTAssertTrue(navlog.contains("SENTINEL-\(vector) -> cancel"),
                          "\(label): the sandboxed frame's navigation was not cancelled by the policy — navlog: \(navlog)")
            XCTAssertFalse(navlog.contains("SENTINEL-\(vector) -> allow"),
                           "\(label): the sandboxed frame's navigation was allowed — navlog: \(navlog)")
        }
    }

    // MARK: - AGF-3715: a tapped magic link reaches the OPEN sign-in / sign-up page with its fragment

    // The sign-in / sign-up link (`https://ai.myra.eu/login#token=…`) is bound to the browser that requested it —
    // in the app, this web view's own cookie jar — and its token rides the FRAGMENT. In the app the user usually
    // still sits on /login (or /signup) when the tapped link arrives, so only the fragment changes: the shell must
    // hand the universal link to the SAME web view and WebKit must deliver it to the open document (the SPA's
    // boot-registered popstate / hashchange listeners take the token there). The page is a probe placed AT the
    // real address (MYRA_UITEST_HTML_BASE); the link goes through the app's universal-link handler; hermetic — a
    // navigation that would leave the document is cancelled (`NAV hermetic … -> cancel`) and fails the test.
    func test_magic_link_reaches_open_login_page() throws { try assertMagicLinkDelivered("/login") }
    func test_magic_link_reaches_open_signup_page() throws { try assertMagicLinkDelivered("/signup") }

    private func assertMagicLinkDelivered(_ path: String) throws {
        let token = "ml\(nonce)"
        let app = XCUIApplication()
        app.launchArguments += ["-MyraUITestHTML", "-MyraUITestSuppressPushPrompt",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-MyraUITestUserActivityURL", "https://ai.myra.eu\(path)#token=\(token)"]
        app.launchEnvironment["MYRA_UITEST_HTML"] = magicLinkProbe
        app.launchEnvironment["MYRA_UITEST_HTML_BASE"] = "https://ai.myra.eu\(path)"
        app.launch()
        XCTAssertTrue(waitForNavlog(app, containing: "PAGE magiclink path=\(path)", timeout: 30),
                      "the probe page did not load at \(path) — is the MYRA_UITEST_HTML_BASE hook in this (Debug) build?")
        let delivered = waitForNavlog(app, containing: "hash=#token=\(token)", timeout: 20)
        let label = "magiclink\(path.replacingOccurrences(of: "/", with: "_"))"
        capture(app, label)
        let navlog = readNavlog(app)
        log("\(label) delivered=\(delivered) navlog=\(navlog)")
        XCTAssertTrue(delivered, "\(path): the tapped link never reached the open page with its fragment — navlog: \(navlog)")
        XCTAssertFalse(navlog.contains("NAV hermetic"),
                       "\(path): the link was loaded as a NEW document instead of reaching the open one — navlog: \(navlog)")
    }

    private let magicLinkProbe = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <style>#navlog{margin:0;padding:8px;white-space:pre-wrap;font:12px monospace}</style></head>
    <body><pre id="navlog" aria-label="navlog">NAVLOG</pre><script>
    (function () {
      var log = document.getElementById("navlog");
      window.__navlog = function (line) { log.textContent += "\\n" + line; };
      window.__navlog("PAGE magiclink path=" + location.pathname + " hash=" + location.hash);
      window.addEventListener("popstate", function () { window.__navlog("POPSTATE hash=" + location.hash); });
      window.addEventListener("hashchange", function () { window.__navlog("HASHCHANGE hash=" + location.hash); });
    })();
    </script></body></html>
    """

    private func launchProbe(vector: String, variant: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-MyraUITestHTML", "-MyraUITestSuppressPushPrompt",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["MYRA_UITEST_HTML"] = probePage(vector: vector, variant: variant)
        app.launch()
        XCTAssertTrue(waitForNavlog(app, containing: "PAGE vector=\(vector)", timeout: 30),
                      "the probe page did not load — is the -MyraUITestHTML hook in this (Debug) build?")
        return app
    }

    /// The probe page with its placeholders filled. The host document is embedded as a JSON string with every
    /// "<" escaped, so its own </script> cannot end the page's script.
    private func probePage(vector: String, variant: String) -> String {
        let host = fixture("sandboxHost")
        let data = (try? JSONSerialization.data(withJSONObject: [host])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        let json = String(array.dropFirst().dropLast()).replacingOccurrences(of: "<", with: "\\u003c")
        return fixture("navprobe")
            .replacingOccurrences(of: "__NONCE__", with: nonce)
            .replacingOccurrences(of: "__VECTOR__", with: vector)
            .replacingOccurrences(of: "__VARIANT__", with: variant)
            .replacingOccurrences(of: "__HOST_JSON__", with: json)
    }

    private func fixture(_ name: String) -> String {
        guard let url = Bundle(for: NavigationGuards.self).url(forResource: name, withExtension: "html"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("fixture \(name).html missing from the UI-test bundle")
            return ""
        }
        return text
    }

    /// True when the system browser reached the foreground (or our app left it) within the window.
    private func observeSystemBrowser(_ app: XCUIApplication, seconds: TimeInterval? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(seconds ?? observeSeconds)
        while Date() < deadline {
            if systemBrowserShown(app) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return systemBrowserShown(app)
    }

    /// Safari in front, our app out of it, or Safari's address bar showing the sentinel host. Measured (AGF-3778
    /// runs): with Safari on a first-launch tip sheet both process states can stay stale while the screenshot shows
    /// Safari with exfil.example — its own address bar is the signal that does not depend on them.
    private func systemBrowserShown(_ app: XCUIApplication) -> Bool {
        let browser = safari
        if browser.state == .runningForeground || app.state != .runningForeground { return true }
        let sentinel = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "exfil.example", "exfil.example")
        return browser.descendants(matching: .any).matching(sentinel).firstMatch.exists
    }

    /// A real user tap inside the preview frame (its full-size link), anchored on the app link right below the
    /// frame. Measured: tapping the link element exposed from inside the nested frame lands nowhere, and raw
    /// web-view coordinates are unreliable — an anchored coordinate is what reaches the frame.
    private func tapPreviewLink(_ app: XCUIApplication) {
        let anchor = app.links["agf3766 app link"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 5), "no anchor to tap the preview by")
        anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -120)).tap()
    }

    private func waitForNavlog(_ app: XCUIApplication, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readNavlog(app).contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// The app's log shows a hand-off: its one hand-off point (EXTERNAL …) or a policy verdict "-> external".
    private func handedOff(_ navlog: String) -> Bool {
        navlog.contains("EXTERNAL ") || navlog.contains("-> external")
    }

    /// Bring our app back to the front (a hand-off may have put Safari there) and read the probe log.
    private func foregroundNavlog(_ app: XCUIApplication) -> String {
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        _ = app.webViews.firstMatch.waitForExistence(timeout: 10)
        return readNavlog(app)
    }

    /// The probe page's log, as exposed to accessibility (one or more static texts).
    private func readNavlog(_ app: XCUIApplication) -> String {
        let texts = app.webViews.firstMatch.staticTexts
        return texts.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "navguard_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func log(_ line: String) {
        let flat = line.replacingOccurrences(of: "\n", with: " | ")
        print("NAVGUARD \(flat)")
        NSLog("NAVGUARD %@", flat)
    }
}
