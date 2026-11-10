import XCTest

/// AGF-6849 - the APNs device-token bridge (`window.webkit.messageHandlers.getDeviceToken`), proven in the real app.
///
/// The shell used to PUSH the token into every page that finished loading (`window.__myraApnsToken` + a
/// `myra:apns-token` event), whatever its origin. Now it is request/reply, as on Android (AGF-6813): the SPA posts a
/// callback name `__myraOnPushToken_<n>`, the shell calls `window[name](token|null)` in the document that asked, and
/// nowhere else; the token is never pushed. The decision table is unit tested (DeviceTokenPolicyTests); these guards
/// prove the wiring against a real WKWebView with the hermetic probe page (DEBUG hook `-MyraUITestHTML`).
///
/// A fake token is made known with the DEBUG hook `-MyraUITestApnsToken <hex>`; with `-MyraUITestHoldApnsToken` it is
/// HELD until the page posts "release" (AGF-6890: the test decides when, no timer started at launch), the
/// replaced-document case with `-MyraUITestDeviceTokenReplaceOnPark`. The app writes its own
/// decision lines (`TOKEN ...`, never the token or the callback name) into the page's log; the page logs what it
/// receives (`TREPLY ...`) and any legacy push (`PUSHED ...`). Every negative case first waits for the page's
/// `*SENT` marker (the request really left) and for the native refusal line, so "nothing arrived" is not vacuous.
final class DeviceTokenGuards: XCTestCase {

    private let fake = "deadbeef0123456789abcdef"
    private let hold = "-MyraUITestHoldApnsToken"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIApplication().terminate()
        super.tearDown()
    }

    // MARK: 1. The app's own page asks and gets the token

    func test_01_spa_page_asks_and_gets_the_token() {
        let app = launchProbe()
        // No hold flag: the DEBUG release handler is not registered at all.
        XCTAssertTrue(waitForNavlog(app, containing: "RELH undefined", timeout: 10), "navlog: \(readNavlog(app))")
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 1 ", timeout: 10), "no reply - navlog: \(readNavlog(app))")
        XCTAssertTrue(lines(app).contains("TREPLY 1 tok=\(fake)"), "navlog: \(readNavlog(app))")
        XCTAssertTrue(lines(app).contains("TOKEN reply token"), "navlog: \(readNavlog(app))")
        // A second ask is answered too.
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 2 tok=\(fake)", timeout: 10), "navlog: \(readNavlog(app))")
    }

    // MARK: 2. A foreign origin gets nothing

    func test_02a_api_host_page_gets_no_reply() {
        assertForeignOriginRefused(base: "https://ai-api.myra.eu/")
    }

    func test_02b_owned_subdomain_page_gets_no_reply() {
        assertForeignOriginRefused(base: "https://evil.ai.myra.eu/")
    }

    private func assertForeignOriginRefused(base: String) {
        let app = launchProbe(base: base)
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TSENT 1", timeout: 5), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN refused frame", timeout: 5),
                      "the refusal was not decided natively - navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.5)
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("TREPLY"), "a foreign origin got a reply - navlog: \(log)")
        XCTAssertFalse(log.contains("PUSHED"), "a foreign origin got the token pushed - navlog: \(log)")
        XCTAssertFalse(log.contains("TOKEN reply"), "the shell answered a foreign origin - navlog: \(log)")
    }

    // MARK: 3. Nothing is pushed into a page that did not ask

    func test_03_token_is_not_pushed_into_a_page_that_never_asked() {
        let app = launchProbe()
        Thread.sleep(forTimeInterval: 4.0)   // past the page finishing its load and the page's own polling
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("PUSHED"), "the token was pushed into a page that did not ask - navlog: \(log)")
        XCTAssertFalse(log.contains("TREPLY"), "navlog: \(log)")
        // Positive control: the token was known the whole time, and asking gets it.
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 1 tok=\(fake)", timeout: 10), "navlog: \(readNavlog(app))")
    }

    func test_03b_a_late_token_is_not_pushed_into_a_page_that_never_asked() {
        let app = launchProbe(extra: [hold])
        XCTAssertTrue(waitForNavlog(app, containing: "RELH object", timeout: 10), "navlog: \(readNavlog(app))")
        assertReleasedTokenIsNotPushed(app)
    }

    /// AGF-6890: the slow-simulator race, made deterministic. The page loads 5 s after launch
    /// (`-MyraUITestProbeLoadDelay`); the token is held, so it cannot arrive before the page exists - the test releases
    /// it once it has seen the page. (On the old launch-relative timer this case was red by construction.)
    func test_03c_a_token_released_after_a_slow_page_exists_is_not_pushed() {
        let app = launchProbe(extra: [hold, "-MyraUITestProbeLoadDelay", "5"])
        XCTAssertTrue(waitForNavlog(app, containing: "RELH object", timeout: 10), "navlog: \(readNavlog(app))")
        XCTAssertFalse(readNavlog(app).contains("TOKEN arrived"), "the held token arrived by itself - navlog: \(readNavlog(app))")
        assertReleasedTokenIsNotPushed(app)
    }

    /// Release the held token while the page exists and has not asked: the token arrives with nothing waiting, nothing
    /// is pushed, and asking afterwards gets it.
    private func assertReleasedTokenIsNotPushed(_ app: XCUIApplication) {
        release(app, n: 1)
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN arrived parked=0", timeout: 10),
                      "the token did not arrive natively - navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.5)   // negative window: a push would come right after the arrival
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("PUSHED"), "the late token was pushed into a page that did not ask - navlog: \(log)")
        XCTAssertFalse(log.contains("TREPLY"), "navlog: \(log)")
        let all = lines(app)
        XCTAssertEqual(count(app, "TOKEN release ok"), 1, "navlog: \(log)")
        if let ok = all.firstIndex(of: "TOKEN release ok"), let arrived = all.firstIndex(of: "TOKEN arrived parked=0") {
            XCTAssertLessThan(ok, arrived, "release ok must precede arrival - navlog: \(log)")
        }
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 1 tok=\(fake)", timeout: 10), "navlog: \(readNavlog(app))")
    }

    // MARK: 4. A subframe is not the SPA

    func test_04_subframe_request_gets_no_reply() {
        let app = launchProbe()
        tap(app, "tok-frame")
        XCTAssertTrue(waitForNavlog(app, containing: "FRAMESENT", timeout: 10), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN refused frame", timeout: 5), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.5)
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("TREPLY"), "a subframe got a reply - navlog: \(log)")
        XCTAssertFalse(log.contains("TOKEN reply"), "navlog: \(log)")
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 1 tok=\(fake)", timeout: 10), "the main frame is refused too - navlog: \(readNavlog(app))")
    }

    // MARK: 5. Bad names are ignored

    func test_05_bad_callback_names_get_no_reply() {
        let app = launchProbe()
        tap(app, "tok-bad")
        XCTAssertTrue(waitForNavlog(app, containing: "BADSENT", timeout: 5), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN refused name", timeout: 5),
                      "the refusals were not decided natively - navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.5)
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("TREPLY"), "a bad name got a reply - navlog: \(log)")
        XCTAssertFalse(log.contains("REPLYBAD"), "a name of another bridge got a reply - navlog: \(log)")
        XCTAssertFalse(log.contains("TOKEN reply"), "navlog: \(log)")
        XCTAssertFalse(log.contains("TOKEN parked"), "navlog: \(log)")
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 1 tok=\(fake)", timeout: 10), "the refusals wedged something - navlog: \(readNavlog(app))")
    }

    // MARK: 6. A request made before the token is known is answered when it arrives

    func test_06_late_token_answers_the_parked_request() {
        let app = launchProbe(extra: [hold])
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN parked n=1", timeout: 10), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 2.0)   // negative window: the token is held, so nothing may answer
        XCTAssertFalse(readNavlog(app).contains("TREPLY"), "answered before the token existed - navlog: \(readNavlog(app))")
        XCTAssertFalse(readNavlog(app).contains("TOKEN arrived"), "navlog: \(readNavlog(app))")
        release(app, n: 1)
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 1 tok=\(fake)", timeout: 15), "navlog: \(readNavlog(app))")
        XCTAssertTrue(lines(app).contains("TOKEN arrived parked=1"), "navlog: \(readNavlog(app))")
        XCTAssertEqual(lines(app).filter { $0.hasPrefix("TREPLY") }.count, 1, "navlog: \(readNavlog(app))")
        // A second release finds nothing held: observable, and it changes nothing.
        release(app, n: 2)
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN release none", timeout: 10), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(count(app, "TOKEN release none"), 1, "navlog: \(readNavlog(app))")
        XCTAssertEqual(count(app, "TOKEN release ok"), 1, "navlog: \(readNavlog(app))")
        XCTAssertEqual(lines(app).filter { $0.hasPrefix("TOKEN arrived") }.count, 1, "navlog: \(readNavlog(app))")
        XCTAssertEqual(lines(app).filter { $0.hasPrefix("TREPLY") }.count, 1, "navlog: \(readNavlog(app))")
    }

    func test_06b_the_ninth_parked_request_is_answered_null() {
        let app = launchProbe(extra: [hold])
        tap(app, "tok-nine")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN full", timeout: 10), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 9 null", timeout: 10), "the ninth was not answered null - navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 2.0)   // negative window: the eight parked ones stay unanswered
        let held = lines(app)
        XCTAssertEqual(held.filter { $0.hasPrefix("TREPLY") }, ["TREPLY 9 null"], "navlog: \(readNavlog(app))")
        XCTAssertEqual(held.filter { $0.hasPrefix("TOKEN reply") }, ["TOKEN reply null"], "navlog: \(readNavlog(app))")
        release(app, n: 1)
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN arrived parked=8", timeout: 15), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 8 tok=\(fake)", timeout: 10), "navlog: \(readNavlog(app))")
    }

    // MARK: 6c. The DEBUG release input is itself untrusted

    /// A subframe and every non-"release" body are refused; nothing is released, nothing is answered; a real release
    /// afterwards still works (the refusals wedged nothing).
    func test_06c_the_release_handler_refuses_a_subframe_and_bad_bodies() {
        let app = launchProbe(extra: [hold])
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN parked n=1", timeout: 10), "navlog: \(readNavlog(app))")
        let bad = app.webViews.firstMatch.buttons["tok-release-bad"]
        XCTAssertTrue(bad.waitForExistence(timeout: 10), "no tok-release-bad button")
        XCTAssertTrue(tapAcknowledged(app, bad, ack: "RBADSENT"), "navlog: \(readNavlog(app))")
        let frame = app.webViews.firstMatch.buttons["tok-frame-release"]
        XCTAssertTrue(frame.waitForExistence(timeout: 10), "no tok-frame-release button")
        XCTAssertTrue(tapAcknowledged(app, frame, ack: "FRAMERCLICK"), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "FRAMERSENT", timeout: 15), "the frame never posted its release - navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForLineCount(app, "TOKEN release refused body", 6, timeout: 15), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForLineCount(app, "TOKEN release refused frame", 1, timeout: 15), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 2.0)   // negative window: a wrongly accepted release would arrive by now
        let log = readNavlog(app)
        XCTAssertEqual(count(app, "TOKEN release refused body"), 6, "navlog: \(log)")
        XCTAssertEqual(count(app, "TOKEN release refused frame"), 1, "navlog: \(log)")
        XCTAssertEqual(count(app, "TOKEN release recv main=true"), 6, "navlog: \(log)")
        XCTAssertEqual(count(app, "TOKEN release recv main=false"), 1, "navlog: \(log)")
        XCTAssertEqual(count(app, "TOKEN release ok"), 0, "navlog: \(log)")
        XCTAssertEqual(count(app, "TOKEN release none"), 0, "navlog: \(log)")
        XCTAssertFalse(log.contains("TOKEN arrived"), "a refused release made the token known - navlog: \(log)")
        XCTAssertFalse(log.contains("TREPLY"), "navlog: \(log)")
        release(app, n: 1)
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 1 tok=\(fake)", timeout: 15), "the refusals wedged something - navlog: \(readNavlog(app))")
    }

    // MARK: 6d. A release with nothing held

    func test_06d_a_release_without_a_held_token_is_a_reported_no_op() {
        let app = launchProbe(extra: [hold], withToken: false)
        release(app, n: 1)
        XCTAssertTrue(waitForLineCount(app, "TOKEN release none", 1, timeout: 10), "navlog: \(readNavlog(app))")
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN parked n=1", timeout: 10), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 2.0)   // negative window: there is no token to answer with
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("TREPLY"), "answered with no token - navlog: \(log)")
        XCTAssertFalse(log.contains("TOKEN arrived"), "navlog: \(log)")
        XCTAssertEqual(count(app, "TOKEN release ok"), 0, "navlog: \(log)")
    }

    // MARK: 7. The document is replaced while the request waits

    func test_07_parked_reply_is_not_delivered_into_a_replaced_document() {
        let app = launchProbe(extra: [hold, "-MyraUITestDeviceTokenReplaceOnPark"])
        XCTAssertTrue(lines(app).contains("PAGE 1"), "navlog: \(readNavlog(app))")
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "PAGE 2", timeout: PageLoad.failureCeiling),
                      "the document was not replaced - navlog: \(readNavlog(app))")
        release(app, n: 1)   // from the new document
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN drop replaced", timeout: 15), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.5)   // the new page defines every callback name
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("TREPLY"), "the old request was answered into the new document - navlog: \(log)")
        XCTAssertFalse(log.contains("PUSHED"), "navlog: \(log)")
    }

    // MARK: 8. The user agent carries exactly one app token, with the OS build segment (AGF-7213)

    func test_08_user_agent_carries_one_token_with_os_build() throws {
        let app = launchProbe()
        let uaLines = lines(app).filter { $0.hasPrefix("UA ") }
        XCTAssertEqual(uaLines.count, 1, "navlog: \(readNavlog(app))")
        let ua = String((uaLines.first ?? "").dropFirst(3))
        XCTAssertEqual(ua.components(separatedBy: "MYRAai-").count - 1, 1, "not exactly one MYRAai- in: \(ua)")
        let range = try XCTUnwrap(ua.range(of: "MYRAai-iOS/"), "no iOS token in: \(ua)")
        XCTAssertTrue(range.lowerBound > ua.startIndex && ua[ua.index(before: range.lowerBound)] == " ",
                      "the token is not preceded by one space: \(ua)")
        let spaceIdx = ua.index(before: range.lowerBound)
        XCTAssertTrue(spaceIdx > ua.startIndex && !ua[ua.index(before: spaceIdx)].isWhitespace,
                      "the token is not separated by exactly one space: \(ua)")
        let token = String(ua[range.lowerBound...])
        let pattern = "^MYRAai-iOS/[0-9][0-9.]{0,31} \\([0-9]{1,10}\\) [A-Za-z0-9._,-]{1,128} / iOS [A-Za-z0-9._-]{1,32} / arm64e / build=[A-Za-z0-9._-]{1,64}$"
        XCTAssertNotNil(token.range(of: pattern, options: .regularExpression),
                        "token does not match the grammar with a build= segment: \(token)")
    }

    // MARK: - Engine

    private func lines(_ app: XCUIApplication) -> [String] {
        readNavlog(app).split(separator: "\n").map(String.init)
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.webViews.firstMatch.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(id) button in the probe page")
        button.tap()
    }

    /// Number of log lines that are exactly `line` (never a prefix match: "TOKEN release ok" vs a longer line).
    private func count(_ app: XCUIApplication, _ line: String) -> Int {
        lines(app).filter { $0 == line }.count
    }

    private func waitForLineCount(_ app: XCUIApplication, _ line: String, _ n: Int, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { count(app, line) >= n }
    }

    /// Asks the app to release the held fake token (the n-th release click of this document). The page logs
    /// `RSENT <n>` before posting, so the acknowledged tap is never doubled.
    private func release(_ app: XCUIApplication, n: Int) {
        let button = app.webViews.firstMatch.buttons["tok-release"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no tok-release button in the probe page")
        XCTAssertTrue(tapAcknowledged(app, button, ack: "RSENT \(n)"), "release tap not acknowledged - navlog: \(readNavlog(app))")
    }

    private func launchProbe(extra: [String] = [], base: String? = nil, withToken: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var args: [String] = ["-MyraUITestHTML", "-MyraUITestSuppressPushPrompt"]
        if withToken { args += ["-MyraUITestApnsToken", fake] }
        args += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        args += extra
        app.launchArguments += args
        app.launchEnvironment["MYRA_UITEST_HTML"] = probePage
        if let base { app.launchEnvironment["MYRA_UITEST_HTML_BASE"] = base }
        app.launch()
        XCTAssertTrue(waitForNavlog(app, containing: "PAGE 1", timeout: PageLoad.failureCeiling),
                      "the probe page did not load - is the -MyraUITestHTML hook in this (Debug) build?")
        return app
    }

    private let probePage = #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <style>#navlog{margin:0;padding:8px;white-space:pre-wrap;font:12px monospace}button{font-size:14px;margin:2px;padding:6px}body{padding-top:120px;margin:0}</style></head>
    <body>
    <button id="tok-go" aria-label="tok-go">tok-go</button>
    <button id="tok-nine" aria-label="tok-nine">tok-nine</button>
    <button id="tok-bad" aria-label="tok-bad">tok-bad</button>
    <button id="tok-frame" aria-label="tok-frame">tok-frame</button>
    <button id="tok-release" aria-label="tok-release">tok-release</button>
    <button id="tok-release-bad" aria-label="tok-release-bad">tok-release-bad</button>
    <button id="tok-frame-release" aria-label="tok-frame-release">tok-frame-release</button>
    <pre id="navlog" aria-label="navlog">NAVLOG</pre><script>
    (function () {
      var log = document.getElementById("navlog");
      window.__navlog = function (line) { log.textContent += "\n" + line; };
      var N = window.__navlog;
      var pages = 1;
      try {
        pages = (parseInt(sessionStorage.getItem("pages") || "0", 10) || 0) + 1;
        sessionStorage.setItem("pages", String(pages));
      } catch (e) {}
      N("PAGE " + pages);
      // AGF-7213: the user agent the page really sees (the app token rides in applicationNameForUserAgent).
      N("UA " + navigator.userAgent);
      // Is the DEBUG release handler registered? (Only in a run with -MyraUITestHoldApnsToken.)
      N("RELH " + typeof window.webkit.messageHandlers.uiTestReleaseApnsToken);
      // The legacy push (window.__myraApnsToken / myra:apns-token) must never happen.
      var pushed = false;
      function pushedNow(how) { if (!pushed) { pushed = true; N("PUSHED " + how); } }
      window.addEventListener("myra:apns-token", function () { pushedNow("event"); });
      var polls = 0;
      var iv = setInterval(function () {
        if (window.__myraApnsToken !== undefined) pushedNow("prop");
        if (++polls > 120) clearInterval(iv);
      }, 200);
      var seq = 0;
      function handler(id) {
        return function (r) { N("TREPLY " + id + " " + (r === null ? "null" : "tok=" + r)); };
      }
      // Every name this page can ask for is defined up front, also in a document that replaced the asking one.
      for (var i = 1; i <= 9; i++) window["__myraOnPushToken_" + i] = handler(i);
      window["__myraOnPushToken_1\n"] = function () { N("REPLYBAD"); };
      window["__myraOnViewShot_1"] = function () { N("REPLYBAD"); };
      window["__myraOnNotifPerm_1"] = function () { N("REPLYBAD"); };
      function ask() {
        var id = ++seq;
        window.webkit.messageHandlers.getDeviceToken.postMessage("__myraOnPushToken_" + id);
        N("TSENT " + id);
      }
      document.getElementById("tok-go").onclick = ask;
      document.getElementById("tok-nine").onclick = function () { for (var k = 0; k < 9; k++) ask(); };
      document.getElementById("tok-bad").onclick = function () {
        var h = window.webkit.messageHandlers.getDeviceToken;
        h.postMessage("__myraOnPushToken_1\n"); h.postMessage(42); h.postMessage({}); h.postMessage("x"); h.postMessage(null);
        h.postMessage("__myraOnViewShot_1"); h.postMessage("__myraOnNotifPerm_1"); h.postMessage("__myraOnPushToken_");
        N("BADSENT");
      };
      // Diagnosis only (never asserted): did the touch reach the page, even when no click followed?
      var btns = document.getElementsByTagName("button");
      for (var b = 0; b < btns.length; b++) {
        btns[b].addEventListener("pointerdown", (function (id) { return function () { N("DOWN " + id); }; })(btns[b].id));
      }
      var rseq = 0;
      document.getElementById("tok-release").onclick = function () {
        var id = ++rseq;
        N("RSENT " + id);
        window.webkit.messageHandlers.uiTestReleaseApnsToken.postMessage("release");
      };
      document.getElementById("tok-release-bad").onclick = function () {
        N("RBADSENT");
        var h = window.webkit.messageHandlers.uiTestReleaseApnsToken;
        h.postMessage(42); h.postMessage({}); h.postMessage(null); h.postMessage(""); h.postMessage("Release"); h.postMessage("release ");
      };
      document.getElementById("tok-frame-release").onclick = function () {
        N("FRAMERCLICK");
        var f = document.createElement("iframe");
        f.srcdoc = "<script>window.webkit.messageHandlers.uiTestReleaseApnsToken.postMessage('release');parent.__navlog('FRAMERSENT');<\/script>";
        document.body.appendChild(f);
      };
      document.getElementById("tok-frame").onclick = function () {
        var f = document.createElement("iframe");
        f.srcdoc = "<script>window.webkit.messageHandlers.getDeviceToken.postMessage('__myraOnPushToken_7');parent.__navlog('FRAMESENT');<\/script>";
        document.body.appendChild(f);
      };
    })();
    </script></body></html>
    """#
}
