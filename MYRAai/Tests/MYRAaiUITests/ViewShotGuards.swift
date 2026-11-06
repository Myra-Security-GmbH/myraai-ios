import XCTest

/// AGF-6807 — the native feedback screenshot bridge (`captureViewport`), proven in the real app.
///
/// The SPA asks the shell for the pixels of its own web view (`window.webkit.messageHandlers.captureViewport`,
/// advertised as `__myraNativeCaps.viewSnapshot === true`). The decision table (callback-name shape, size caps, reply
/// shape, gate, replaced-document rule) is unit tested (ViewShotPolicyTests); these guards prove the wiring against a
/// real WKWebView with the hermetic probe page (DEBUG hook `-MyraUITestHTML`, base https://ai.myra.eu/). The app writes
/// its own decision lines (`SHOT …`, never any pixels or the callback name) into the page's log; the page logs every
/// reply it receives (`REPLY <id> …`), validates the delivered JPEG itself (`VALID`) and samples its colour (`PIX`).
///
/// Lifecycle cases use DEBUG launch arguments that only exist in a Debug build: `-MyraUITestViewShotStall <s>` (the
/// snapshot completes that many seconds late), `-MyraUITestViewShotWatchdog <s>`, `-MyraUITestViewShotReplaceOnRequest`
/// (one-shot: the document is replaced while the capture is in flight), `-MyraUITestViewShotFailSnapshot` (one-shot:
/// the snapshot fails) and `-MyraUITestStartLocked` (the biometric lock is up from launch, no auto prompt).
///
/// The full-resolution 1440x3120 frame is covered by the XCTest only (ViewShotPolicyTests): no simulator here renders it.
final class ViewShotGuards: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIApplication().terminate()
        super.tearDown()
    }

    // MARK: 1. The capability

    func test_01_capability_is_the_boolean_true() {
        let app = launchProbe()
        XCTAssertTrue(lines(app).contains("CAPSHOT boolean true"), "navlog: \(readNavlog(app))")
    }

    // MARK: 2. A real, fresh frame

    func test_02_ok_reply_is_a_valid_jpeg_of_the_current_frame() {
        let app = launchProbe(extra: ["-MyraUITestViewShotWatchdog", "10"])  // a slow CI simulator must not trip the 1 s production watchdog
        tap(app, "shot-fresh")   // the page turns green synchronously, then posts
        XCTAssertTrue(waitForNavlog(app, containing: "PIX 1 ", timeout: 15), "no decoded reply — navlog: \(readNavlog(app))")
        let log = lines(app)
        XCTAssertTrue(log.contains { $0.hasPrefix("REPLY 1 ok ") }, "navlog: \(readNavlog(app))")
        XCTAssertTrue(log.contains("VALID 1 yes"), "the reply is not a JPEG of the advertised size — navlog: \(readNavlog(app))")
        XCTAssertTrue(log.contains("SHOT reply ok " + (size(of: "REPLY 1 ok ", in: log).map { "\($0.0)x\($0.1)" } ?? "?")),
                      "native and page disagree on the delivered size — navlog: \(readNavlog(app))")
        // The pixels are the frame the page just painted (green), not a stale one (white).
        let pix = log.first { $0.hasPrefix("PIX 1 ") }.map { $0.split(separator: " ").compactMap { Int($0) } } ?? []
        XCTAssertEqual(pix.count, 4, "navlog: \(readNavlog(app))")
        if pix.count == 4 {
            let (r, g, b) = (pix[1], pix[2], pix[3])
            XCTAssertTrue(g > r + 60 && g > b + 60, "not the fresh green frame: rgb=\(r),\(g),\(b)")
        }
        // The size is the web view's own bounds in pixels, within the caps.
        if let got = size(of: "REPLY 1 ok ", in: log), let exp = expected(1, in: log) {
            let tolW = max(2, exp.0 * 3 / 100), tolH = max(2, exp.1 * 3 / 100)
            XCTAssertTrue(abs(got.0 - exp.0) <= tolW && abs(got.1 - exp.1) <= tolH,
                          "size \(got) is not the viewport \(exp) — navlog: \(readNavlog(app))")
            XCTAssertLessThanOrEqual(max(got.0, got.1), 2560)
        } else {
            XCTFail("could not read the size lines — navlog: \(readNavlog(app))")
        }
        attachScreenshot(prefix: "viewshot", "ok")
        // A warm second capture (after the 0.5 s cooldown) answers promptly: with the 10 s watchdog above, only
        // this bound shows the success reply is not merely arriving "eventually". The cold first shot is not judged.
        // The 0.8 s is measured from PIX 1 (already observed above), so it is past the cooldown that started at reply 1.
        // AGF-6828: the tap is acknowledged by the page's own "POST 2" (logged synchronously in its handler); a tap the
        // simulator dropped is repeated only while that line is absent, so exactly one request is ever sent.
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(tapAcknowledged(app, app.webViews.firstMatch.buttons["shot-go"], ack: "POST 2"),
                      "the second tap never reached the page — navlog: \(readNavlog(app))")
        XCTAssertEqual(lines(app).filter { $0 == "POST 2" }.count, 1, "navlog: \(readNavlog(app))")
        XCTAssertFalse(lines(app).contains("POST 3"), "a repeated tap sent a third request — navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "REPLY 2 ", timeout: 15), "no second reply — navlog: \(readNavlog(app))")
        let second = lines(app).first { $0.hasPrefix("REPLY 2 ") } ?? ""
        XCTAssertTrue(second.hasPrefix("REPLY 2 ok "), "second capture: \(second) — navlog: \(readNavlog(app))")
        let ms = elapsed(second) ?? Int.max
        XCTAssertLessThan(ms, 1500, "the warm second reply was slow: \(second)")
    }

    // MARK: 3. Bad names are ignored

    func test_03_bad_callback_names_get_no_reply_and_no_read() {
        let app = launchProbe(extra: ["-MyraUITestViewShotWatchdog", "10"])  // a slow CI simulator must not trip the 1 s production watchdog
        tap(app, "shot-bad")
        XCTAssertTrue(waitForNavlog(app, containing: "BADSENT", timeout: 5))
        XCTAssertTrue(waitForNavlog(app, containing: "SHOT refused name", timeout: 5),
                      "the refusals were not decided natively — navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.5)
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("REPLY"), "a bad name got a reply — navlog: \(log)")
        XCTAssertFalse(log.contains("SHOT read"), "a bad name read the pixels — navlog: \(log)")
        XCTAssertFalse(log.contains("SHOT busy") || log.contains("SHOT cooling"), "a bad name took the gate — navlog: \(log)")
        // The refusals did not wedge anything.
        tap(app, "shot-go")
        XCTAssertTrue(waitForNavlog(app, containing: "VALID 1 yes", timeout: 15), "navlog: \(readNavlog(app))")
    }

    // MARK: 4. A subframe is not the SPA

    func test_04_subframe_request_gets_no_reply_and_no_read() {
        let app = launchProbe(extra: ["-MyraUITestViewShotWatchdog", "10"])  // a slow CI simulator must not trip the 1 s production watchdog
        tap(app, "shot-frame")
        XCTAssertTrue(waitForNavlog(app, containing: "FRAMESENT", timeout: 10), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.5)
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("REPLY"), "a subframe got a reply — navlog: \(log)")
        XCTAssertFalse(log.contains("SHOT read"), "a subframe read the pixels — navlog: \(log)")
        XCTAssertTrue(lines(app).contains { $0.hasPrefix("DIAG recv main=false") }, "the subframe request was not seen as a subframe — navlog: \(log)")
        tap(app, "shot-go")
        XCTAssertTrue(waitForNavlog(app, containing: "VALID 1 yes", timeout: 15), "the main frame is refused too — navlog: \(readNavlog(app))")
    }

    // MARK: 5. One in flight, then a cooldown

    func test_05_concurrent_and_rapid_requests_are_refused() {
        let app = launchProbe(extra: ["-MyraUITestViewShotWatchdog", "10"])  // a slow CI simulator must not trip the 1 s production watchdog
        tap(app, "shot-cool")   // 1 and 2 in one tick; 3 right after 1's ok reply; 4 at +700 ms
        XCTAssertTrue(waitForNavlog(app, containing: "REPLY 4 ", timeout: 20), "navlog: \(readNavlog(app))")
        let log = lines(app)
        func reply(_ id: Int) -> String { log.first { $0.hasPrefix("REPLY \(id) ") } ?? "none" }
        XCTAssertTrue(reply(1).hasPrefix("REPLY 1 ok "), "first request: \(reply(1)) — navlog: \(readNavlog(app))")
        XCTAssertTrue(reply(2).hasPrefix("REPLY 2 render_error"), "second (concurrent) request: \(reply(2))")
        XCTAssertTrue(reply(3).hasPrefix("REPLY 3 render_error"), "third (inside the cooldown) request: \(reply(3))")
        XCTAssertTrue(reply(4).hasPrefix("REPLY 4 ok "), "fourth (after the cooldown) request: \(reply(4))")
        XCTAssertTrue(log.contains("SHOT busy"), "navlog: \(readNavlog(app))")
        XCTAssertTrue(log.contains("SHOT cooling"), "navlog: \(readNavlog(app))")
        XCTAssertEqual(log.filter { $0 == "SHOT read" || $0.hasPrefix("SHOT read ") }.count, 2,
                       "a refused request read the pixels — navlog: \(readNavlog(app))")
    }

    // MARK: 6. The lock screen is never captured

    func test_06_secure_while_the_lock_is_up_then_ok_after_unlock() {
        let app = launchProbe(extra: ["-MyraUITestStartLocked", "-MyraUITestViewShotWatchdog", "10"], auto: true)  // 10 s: a slow CI simulator must not trip the 1 s production watchdog
        let unlock = app.buttons["Unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 20), "the lock screen is not up")
        attachScreenshot(prefix: "viewshot", "locked")
        // The secure reply was produced while the lock was up (the page asks 400 ms after load, before this tap).
        XCTAssertTrue(waitForNavlog(app, containing: "REPLY 1 secure_view", timeout: 15), "navlog: \(readNavlog(app))")
        var log = lines(app)
        XCTAssertTrue(log.contains("SHOT secure"), "navlog: \(readNavlog(app))")
        XCTAssertFalse(log.contains { $0.hasPrefix("SHOT read") }, "pixels were read behind the lock — navlog: \(readNavlog(app))")
        XCTAssertFalse(log.contains { $0.hasPrefix("VALID") }, "image data was delivered behind the lock — navlog: \(readNavlog(app))")
        unlock.tap()
        XCTAssertTrue(waitForDisappearance(unlock, timeout: 10), "the lock screen is still up after Unlock")
        Thread.sleep(forTimeInterval: 1.5)   // past the cooldown and the lock fade-out
        // AGF-6828: acknowledged by the page's own "POST 2"; repeated only while that line is absent.
        XCTAssertTrue(tapAcknowledged(app, app.webViews.firstMatch.buttons["shot-go"], ack: "POST 2"),
                      "the post-unlock tap never reached the page — navlog: \(readNavlog(app))")
        XCTAssertEqual(lines(app).filter { $0 == "POST 2" }.count, 1, "navlog: \(readNavlog(app))")
        XCTAssertFalse(lines(app).contains("POST 3"), "a repeated tap sent a third request — navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "VALID 2 yes", timeout: 15), "navlog: \(readNavlog(app))")
        log = lines(app)
        XCTAssertTrue(log.contains { $0.hasPrefix("REPLY 2 ok ") }, "navlog: \(readNavlog(app))")
    }

    // MARK: 7. A snapshot that never completes in time

    func test_07_watchdog_settles_once_and_the_late_snapshot_is_discarded() {
        let app = launchProbe(extra: ["-MyraUITestViewShotStall", "3"])
        tap(app, "shot-go")
        XCTAssertTrue(waitForNavlog(app, containing: "REPLY 1 ", timeout: 8), "navlog: \(readNavlog(app))")
        let first = lines(app).first { $0.hasPrefix("REPLY 1 ") } ?? ""
        XCTAssertTrue(first.hasPrefix("REPLY 1 render_error"), first)
        let ms = elapsed(first) ?? -1
        XCTAssertTrue((800...1500).contains(ms), "the watchdog did not fire at ~1 s: \(first)")
        // The stalled snapshot completes at ~3 s: it must be dropped, not delivered.
        XCTAssertTrue(waitForNavlog(app, containing: "SHOT late", timeout: 8), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 1.0)
        let log = lines(app)
        XCTAssertEqual(log.filter { $0.hasPrefix("REPLY ") }.count, 1, "a second reply arrived — navlog: \(readNavlog(app))")
        XCTAssertTrue(log.contains("SHOT settle watchdog"), "navlog: \(readNavlog(app))")
        XCTAssertFalse(log.contains { $0.hasPrefix("VALID") }, "the late frame was delivered — navlog: \(readNavlog(app))")
    }

    // MARK: 8. Backgrounding settles the capture

    func test_08_backgrounding_settles_with_render_error() {
        let app = launchProbe(extra: ["-MyraUITestViewShotStall", "20", "-MyraUITestViewShotWatchdog", "10"])
        tap(app, "shot-go")
        XCTAssertTrue(waitForNavlog(app, containing: "SHOT read", timeout: 10), "navlog: \(readNavlog(app))")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2.0)
        app.activate()
        XCTAssertTrue(waitForNavlog(app, containing: "REPLY 1 ", timeout: 8), "navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "SHOT settle background", timeout: 5), "navlog: \(readNavlog(app))")
        let first = lines(app).first { $0.hasPrefix("REPLY 1 ") } ?? ""
        XCTAssertTrue(first.hasPrefix("REPLY 1 render_error"), first)
        // Neither the 10 s watchdog nor the 20 s snapshot may produce anything more.
        Thread.sleep(forTimeInterval: 12.0)
        let log = lines(app)
        XCTAssertEqual(log.filter { $0.hasPrefix("REPLY ") }.count, 1, "a second reply arrived — navlog: \(readNavlog(app))")
        XCTAssertFalse(log.contains("SHOT settle watchdog"), "the watchdog settled a capture already settled — navlog: \(readNavlog(app))")
    }

    // MARK: 9. The document is replaced mid-capture

    func test_09_reply_is_not_delivered_into_a_replaced_document() {
        let app = launchProbe(extra: ["-MyraUITestViewShotStall", "2", "-MyraUITestViewShotWatchdog", "10",
                                      "-MyraUITestViewShotReplaceOnRequest"])
        XCTAssertTrue(lines(app).contains("PAGE 1"), "navlog: \(readNavlog(app))")
        tap(app, "shot-go")
        XCTAssertTrue(waitForNavlog(app, containing: "PAGE 2", timeout: PageLoad.failureCeiling),
                      "the document was not replaced — navlog: \(readNavlog(app))")
        XCTAssertTrue(waitForNavlog(app, containing: "SHOT drop replaced", timeout: 10), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 2.0)   // past the watchdog-free window; the new page defines every callback name
        let log = readNavlog(app)
        XCTAssertFalse(log.contains("REPLY"), "the old request was answered into the new document — navlog: \(log)")
        XCTAssertFalse(log.contains("VALID"), "image data reached the new document — navlog: \(log)")
    }

    // MARK: 10. The snapshot itself fails

    func test_10_snapshot_failure_is_a_render_error_and_the_next_request_works() {
        let app = launchProbe(extra: ["-MyraUITestViewShotFailSnapshot", "-MyraUITestViewShotWatchdog", "10"])  // a slow CI simulator must not trip the 1 s production watchdog
        tap(app, "shot-go")
        XCTAssertTrue(waitForNavlog(app, containing: "REPLY 1 ", timeout: 8), "navlog: \(readNavlog(app))")
        let first = lines(app).first { $0.hasPrefix("REPLY 1 ") } ?? ""
        XCTAssertTrue(first.hasPrefix("REPLY 1 render_error"), first)
        XCTAssertTrue(waitForNavlog(app, containing: "SHOT settle error", timeout: 5), "navlog: \(readNavlog(app))")
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(lines(app).filter { $0.hasPrefix("REPLY ") }.count, 1, "navlog: \(readNavlog(app))")
        // The failure released the gate (after the cooldown) and the failure hook was one-shot.
        tap(app, "shot-go")
        XCTAssertTrue(waitForNavlog(app, containing: "VALID 2 yes", timeout: 15), "navlog: \(readNavlog(app))")
        XCTAssertTrue(lines(app).contains { $0.hasPrefix("REPLY 2 ok ") }, "navlog: \(readNavlog(app))")
    }

    // MARK: - Engine

    private func lines(_ app: XCUIApplication) -> [String] {
        readNavlog(app).split(separator: "\n").map(String.init)
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { !element.exists }
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.webViews.firstMatch.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(id) button in the probe page")
        button.tap()
    }

    /// `WxH` after the given prefix, from the first line with that prefix.
    private func size(of prefix: String, in log: [String]) -> (Int, Int)? {
        guard let line = log.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let word = line.dropFirst(prefix.count).split(separator: " ").first.map(String.init) ?? ""
        let parts = word.split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// `EXP <id> <w> <h>`: the size the page computes for its own viewport.
    private func expected(_ id: Int, in log: [String]) -> (Int, Int)? {
        guard let line = log.first(where: { $0.hasPrefix("EXP \(id) ") }) else { return nil }
        let n = line.split(separator: " ").compactMap { Int($0) }
        return n.count == 3 ? (n[1], n[2]) : nil
    }

    /// The `t=<ms>` field of a REPLY line.
    private func elapsed(_ line: String) -> Int? {
        guard let field = line.split(separator: " ").first(where: { $0.hasPrefix("t=") }) else { return nil }
        return Int(field.dropFirst(2))
    }

    private func launchProbe(extra: [String] = [], auto: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-MyraUITestHTML", "-MyraUITestSuppressPushPrompt",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launchEnvironment["MYRA_UITEST_HTML"] = probePage.replacingOccurrences(of: "__AUTO__", with: auto ? "true" : "false")
        app.launch()
        if !extra.contains("-MyraUITestStartLocked") {
            XCTAssertTrue(waitForNavlog(app, containing: "PAGE 1", timeout: PageLoad.failureCeiling),
                          "the probe page did not load — is the -MyraUITestHTML hook in this (Debug) build?")
        }
        return app
    }

    private let probePage = #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <style>#navlog{margin:0;padding:8px;white-space:pre-wrap;font:12px monospace}button{font-size:14px;margin:2px;padding:6px}body{padding-top:120px;margin:0}</style></head>
    <body>
    <button id="shot-go" aria-label="shot-go">shot-go</button>
    <button id="shot-fresh" aria-label="shot-fresh">shot-fresh</button>
    <button id="shot-bad" aria-label="shot-bad">shot-bad</button>
    <button id="shot-cool" aria-label="shot-cool">shot-cool</button>
    <button id="shot-frame" aria-label="shot-frame">shot-frame</button>
    <pre id="navlog" aria-label="navlog">NAVLOG</pre><script>
    (function () {
      var log = document.getElementById("navlog");
      window.__navlog = function (line) { log.textContent += "\n" + line; };
      var N = window.__navlog;
      var caps = window.__myraNativeCaps || {};
      var pages = 1;
      try {
        pages = (parseInt(sessionStorage.getItem("pages") || "0", 10) || 0) + 1;
        sessionStorage.setItem("pages", String(pages));
      } catch (e) {}
      N("PAGE " + pages);
      N("CAPSHOT " + typeof caps.viewSnapshot + " " + caps.viewSnapshot);
      var sent = {}, seq = 0, coolWatch = false, coolDone = false;
      function scaled(w, h) {
        var cap = 2560;
        if (Math.max(w, h) > cap) {
          if (w >= h) { h = Math.max(1, Math.floor(h * cap / w)); w = cap; }
          else { w = Math.max(1, Math.floor(w * cap / h)); h = cap; }
        }
        return [w, h];
      }
      function req() {
        var id = ++seq;
        var s = scaled(Math.round(window.innerWidth * window.devicePixelRatio), Math.round(window.innerHeight * window.devicePixelRatio));
        N("EXP " + id + " " + s[0] + " " + s[1]);
        N("POST " + id);
        sent[id] = performance.now();
        window.webkit.messageHandlers.captureViewport.postMessage("__myraOnViewShot_" + id);
        return id;
      }
      function handler(id) {
        return function (r) {
          var t = sent[id] === undefined ? "?" : Math.round(performance.now() - sent[id]);
          if (!r || r.ok !== true) {
            N("REPLY " + id + " " + (r && r.reason) + " t=" + t);
          } else {
            N("REPLY " + id + " ok " + r.width + "x" + r.height + " t=" + t);
          }
          if (coolWatch && !coolDone && r && r.ok === true) { coolDone = true; req(); setTimeout(req, 700); }
          if (!r || r.ok !== true) return;
          var bin;
          try { bin = atob(r.data); } catch (e) { N("VALID " + id + " no base64"); return; }
          var n = bin.length;
          var jpeg = n > 4 && bin.charCodeAt(0) === 255 && bin.charCodeAt(1) === 216 && bin.charCodeAt(2) === 255 &&
                     bin.charCodeAt(n - 2) === 255 && bin.charCodeAt(n - 1) === 217;
          var img = new Image();
          img.onload = function () {
            var same = r.type === "image/jpeg" && img.naturalWidth === r.width && img.naturalHeight === r.height;
            N("VALID " + id + " " + (jpeg && same ? "yes" : "no jpeg=" + jpeg + " dims=" + img.naturalWidth + "x" + img.naturalHeight));
            var c = document.createElement("canvas"); c.width = 8; c.height = 8;
            var g = c.getContext("2d"); g.drawImage(img, 0, 0, 8, 8);
            var d = g.getImageData(0, 0, 8, 8).data, R = 0, G = 0, B = 0;
            for (var k = 0; k < d.length; k += 4) { R += d[k]; G += d[k + 1]; B += d[k + 2]; }
            var m = d.length / 4;
            N("PIX " + id + " " + Math.round(R / m) + " " + Math.round(G / m) + " " + Math.round(B / m));
          };
          img.onerror = function () { N("VALID " + id + " no decode"); };
          img.src = "data:image/jpeg;base64," + r.data;
        };
      }
      // Every name this page can ask for is defined up front, also in a document that replaced the asking one.
      for (var i = 1; i <= 8; i++) window["__myraOnViewShot_" + i] = handler(i);
      window["__myraOnViewShot_1\n"] = function () { N("REPLYBAD"); };
      // Diagnosis only (never asserted): did the touch reach the page, even when no click followed?
      var btns = document.getElementsByTagName("button");
      for (var b = 0; b < btns.length; b++) {
        btns[b].addEventListener("pointerdown", (function (id) { return function () { N("DOWN " + id); }; })(btns[b].id));
      }
      document.getElementById("shot-go").onclick = function () { req(); };
      document.getElementById("shot-fresh").onclick = function () {
        document.documentElement.style.background = "#0b0";
        document.body.style.background = "#0b0";
        req();
      };
      document.getElementById("shot-bad").onclick = function () {
        var h = window.webkit.messageHandlers.captureViewport;
        h.postMessage("__myraOnViewShot_1\n"); h.postMessage(42); h.postMessage({}); h.postMessage("x"); h.postMessage(null);
        N("BADSENT");
      };
      document.getElementById("shot-cool").onclick = function () { coolWatch = true; req(); req(); };
      document.getElementById("shot-frame").onclick = function () {
        var f = document.createElement("iframe");
        f.srcdoc = "<script>window.webkit.messageHandlers.captureViewport.postMessage('__myraOnViewShot_7');parent.__navlog('FRAMESENT');<\/script>";
        document.body.appendChild(f);
      };
      if (__AUTO__) setTimeout(req, 400);
    })();
    </script></body></html>
    """#
}
