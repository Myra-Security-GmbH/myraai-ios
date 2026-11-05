import XCTest

/// AGF-6849 - the APNs device-token bridge (`window.webkit.messageHandlers.getDeviceToken`), proven in the real app.
///
/// The shell used to PUSH the token into every page that finished loading (`window.__myraApnsToken` + a
/// `myra:apns-token` event), whatever its origin. Now it is request/reply, as on Android (AGF-6813): the SPA posts a
/// callback name `__myraOnPushToken_<n>`, the shell calls `window[name](token|null)` in the document that asked, and
/// nowhere else; the token is never pushed. The decision table is unit tested (DeviceTokenPolicyTests); these guards
/// prove the wiring against a real WKWebView with the hermetic probe page (DEBUG hook `-MyraUITestHTML`).
///
/// A fake token is made known with the DEBUG hooks `-MyraUITestApnsToken <hex>` and `-MyraUITestApnsTokenAfter <s>`
/// (it arrives late), the replaced-document case with `-MyraUITestDeviceTokenReplaceOnPark`. The app writes its own
/// decision lines (`TOKEN ...`, never the token or the callback name) into the page's log; the page logs what it
/// receives (`TREPLY ...`) and any legacy push (`PUSHED ...`). Every negative case first waits for the page's
/// `*SENT` marker (the request really left) and for the native refusal line, so "nothing arrived" is not vacuous.
final class DeviceTokenGuards: XCTestCase {

    private let fake = "deadbeef0123456789abcdef"

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
        let app = launchProbe(extra: ["-MyraUITestApnsTokenAfter", "2"])
        // The native side reports the token arriving with nothing waiting. (On a build without that line this is a
        // plain 6 s wait, and the push assertion below carries the case.)
        let arrived = waitForNavlog(app, containing: "TOKEN arrived parked=0", timeout: 6)
        Thread.sleep(forTimeInterval: 1.5)
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("PUSHED"), "the late token was pushed into a page that did not ask - navlog: \(log)")
        XCTAssertFalse(log.contains("TREPLY"), "navlog: \(log)")
        XCTAssertTrue(arrived, "the token did not arrive natively - navlog: \(log)")
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
        let app = launchProbe(extra: ["-MyraUITestApnsTokenAfter", "3"])
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN parked n=1", timeout: 5), "navlog: \(readNavlog(app))")
        XCTAssertFalse(readNavlog(app).contains("TREPLY"), "answered before the token existed - navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 1 tok=\(fake)", timeout: 15), "navlog: \(readNavlog(app))")
        XCTAssertTrue(lines(app).contains("TOKEN arrived parked=1"), "navlog: \(readNavlog(app))")
        XCTAssertEqual(lines(app).filter { $0.hasPrefix("TREPLY") }.count, 1, "navlog: \(readNavlog(app))")
    }

    func test_06b_the_ninth_parked_request_is_answered_null() {
        let app = launchProbe(extra: ["-MyraUITestApnsTokenAfter", "6"])
        tap(app, "tok-nine")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN full", timeout: 5), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 9 null", timeout: 5), "the ninth was not answered null - navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN arrived parked=8", timeout: 15), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TREPLY 8 tok=\(fake)", timeout: 5), "navlog: \(readNavlog(app))")
    }

    // MARK: 7. The document is replaced while the request waits

    func test_07_parked_reply_is_not_delivered_into_a_replaced_document() {
        let app = launchProbe(extra: ["-MyraUITestApnsTokenAfter", "8", "-MyraUITestDeviceTokenReplaceOnPark"])
        XCTAssertTrue(lines(app).contains("PAGE 1"), "navlog: \(readNavlog(app))")
        tap(app, "tok-go")
        XCTAssertTrue(waitForNavlog(app, containing: "PAGE 2", timeout: 15),
                      "the document was not replaced - navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "TOKEN drop replaced", timeout: 25), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.5)   // the new page defines every callback name
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("TREPLY"), "the old request was answered into the new document - navlog: \(log)")
        XCTAssertFalse(log.contains("PUSHED"), "navlog: \(log)")
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

    private func launchProbe(extra: [String] = [], base: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-MyraUITestHTML", "-MyraUITestSuppressPushPrompt", "-MyraUITestApnsToken", fake,
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launchEnvironment["MYRA_UITEST_HTML"] = probePage
        if let base { app.launchEnvironment["MYRA_UITEST_HTML_BASE"] = base }
        app.launch()
        XCTAssertTrue(waitForNavlog(app, containing: "PAGE 1", timeout: 30),
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
      document.getElementById("tok-frame").onclick = function () {
        var f = document.createElement("iframe");
        f.srcdoc = "<script>window.webkit.messageHandlers.getDeviceToken.postMessage('__myraOnPushToken_7');parent.__navlog('FRAMESENT');<\/script>";
        document.body.appendChild(f);
      };
    })();
    </script></body></html>
    """#
}
