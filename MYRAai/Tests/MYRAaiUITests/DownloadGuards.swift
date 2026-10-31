import XCTest
import UIKit

/// AGF-3621 — files the app page saves reach the user through the share sheet, and nothing else downloads.
///
/// The SPA saves a file by clicking `<a download=name href=blob:…>`; WebKit raises a download action which the app
/// answers with WKDownload (blob:/data: from the app page into the main frame only) and then shows the share sheet.
/// These guards load a probe page (DEBUG hook `-MyraUITestHTML`, base https://ai.myra.eu/ — the app page for the
/// sender check) and tap its buttons (a user gesture). Detection does not trust the code under test: the share
/// sheet and the alert are observed through accessibility. The app's own decision log (`DOWNLOAD … -> …`, written
/// into the probe page) is asserted too and is what the screenshot shows. One screenshot per test is attached.
final class DownloadGuards: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Tests

    /// A normal save: share sheet appears, no alert; a name with &, parentheses and € is accepted.
    func test_blob_download_opens_share_sheet() throws {
        let app = launchProbe()
        tap(app, "save-ok")
        let sheet = waitForShareSheet(app, timeout: 20)
        capture(app, "blob_ok")
        let navlog = readNavlog(app)
        log("blob_ok shareSheet=\(sheet) navlog=\(navlog)")
        XCTAssertTrue(navlog.contains("DOWNLOAD action scheme=blob -> download"), "the app never decided to download — navlog: \(navlog)")
        XCTAssertTrue(sheet, "the blob download did not open the share sheet (if the alert shows instead, check expectedContentLength) — navlog: \(navlog)")
        XCTAssertFalse(app.alerts["Could not save the file"].exists, "the failure alert showed for a valid file")
    }

    /// A page-controlled filename with a bidi override is rejected: alert, no sheet.
    func test_bad_filename_is_rejected_with_alert() throws {
        let app = launchProbe()
        tap(app, "save-badname")
        let alert = app.alerts["Could not save the file"]
        let shown = alert.waitForExistence(timeout: 20)
        let sheet = waitForShareSheet(app, timeout: 3)
        capture(app, "bad_filename")
        log("bad_filename alert=\(shown) shareSheet=\(sheet) navlog=\(readNavlog(app))")
        XCTAssertTrue(shown, "a bidi-override filename was not rejected with the alert")
        XCTAssertFalse(sheet, "a rejected download still opened the share sheet")
    }

    /// The same click inside a sandboxed (opaque-origin) srcdoc iframe — a preview: cancelled silently.
    func test_sandboxed_preview_download_is_cancelled_silently() throws {
        let app = launchProbe()
        XCTAssertTrue(waitForNavlog(app, containing: "PREVIEW loaded", timeout: 15), "the preview never rendered — vacuous")
        tap(app, "save-in-preview")
        let decided = waitForNavlog(app, containing: "DOWNLOAD action scheme=blob -> cancelSilently", timeout: 15)
        let sheet = waitForShareSheet(app, timeout: 4)
        capture(app, "preview_cancelled")
        let navlog = readNavlog(app)
        log("preview_cancelled decided=\(decided) shareSheet=\(sheet) navlog=\(navlog)")
        XCTAssertTrue(decided, "the preview's download never reached the policy (or was not cancelled silently) — navlog: \(navlog)")
        XCTAssertFalse(sheet, "a sandboxed preview's download opened the share sheet")
        XCTAssertFalse(app.alerts["Could not save the file"].exists, "a preview's download showed an alert")
    }

    /// 100 MiB + 1 byte: over the cap — alert, no sheet.
    func test_oversize_blob_is_rejected_with_alert() throws {
        let app = launchProbe()
        tap(app, "save-big")
        let alert = app.alerts["Could not save the file"]
        let shown = alert.waitForExistence(timeout: 30)
        let sheet = waitForShareSheet(app, timeout: 3)
        capture(app, "oversize")
        log("oversize alert=\(shown) shareSheet=\(sheet) navlog=\(readNavlog(app))")
        XCTAssertTrue(shown, "a blob over 100 MiB was not rejected with the alert")
        XCTAssertFalse(sheet, "an oversize download opened the share sheet")
    }

    // MARK: - Engine

    private func launchProbe() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-MyraUITestHTML", "-MyraUITestSuppressPushPrompt",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["MYRA_UITEST_HTML"] = probePage
        app.launch()
        XCTAssertTrue(waitForNavlog(app, containing: "PAGE downloads", timeout: 30),
                      "the probe page did not load — is the -MyraUITestHTML hook in this (Debug) build?")
        return app
    }

    private func tap(_ app: XCUIApplication, _ label: String) {
        let button = app.webViews.firstMatch.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no button \(label) in the probe page")
        button.tap()
        XCTAssertTrue(waitForNavlog(app, containing: "CLICK \(label)", timeout: 5),
                      "the tap did not reach the button \(label) (no CLICK line) — navlog: \(readNavlog(app))")
    }

    /// Every button builds a Blob and clicks an `<a download>` on it from its own click handler (a user gesture).
    /// The preview is a sandboxed srcdoc iframe (opaque origin) with the same kind of button.
    private let probePage = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <style>#navlog{margin:0;padding:8px;white-space:pre-wrap;font:12px monospace}button{font-size:18px;margin:4px;padding:8px}body{padding-top:140px}</style></head>
    <body>
    <button id="save-ok" aria-label="save-ok">save-ok</button>
    <button id="save-badname" aria-label="save-badname">save-badname</button>
    <button id="save-big" aria-label="save-big">save-big</button>
    <iframe id="preview" sandbox="allow-scripts allow-downloads" style="width:100%;height:80px;border:1px solid #888"></iframe>
    <pre id="navlog" aria-label="navlog">NAVLOG</pre><script>
    (function () {
      var log = document.getElementById("navlog");
      window.__navlog = function (line) { log.textContent += "\\n" + line; };
      function save(bytes, name) {
        var a = document.createElement("a");
        a.href = URL.createObjectURL(new Blob([bytes], { type: "text/plain" }));
        a.download = name;
        document.body.appendChild(a);
        a.click();
        a.remove();
      }
      document.getElementById("save-ok").onclick = function () { window.__navlog("CLICK save-ok"); save("hello", "Bericht (\\u20AC) Q&A.txt"); };
      document.getElementById("save-badname").onclick = function () { window.__navlog("CLICK save-badname"); save("hello", "x\\u202Etxt.exe"); };
      document.getElementById("save-big").onclick = function () { window.__navlog("CLICK save-big"); save(new Uint8Array(100 * 1024 * 1024 + 1), "big.bin"); };
      document.getElementById("preview").srcdoc =
        '<button id="b" aria-label="save-in-preview">save-in-preview</button><script>' +
        'document.getElementById("b").onclick=function(){parent.postMessage("click","*");var a=document.createElement("a");' +
        'a.href=URL.createObjectURL(new Blob(["x"]));a.download="p.txt";document.body.appendChild(a);a.click();};' +
        'parent.postMessage("loaded","*");<' + '/script>';
      window.addEventListener("message", function (e) { if (e.data === "loaded") window.__navlog("PREVIEW loaded"); if (e.data === "click") window.__navlog("CLICK save-in-preview"); });
      window.__navlog("PAGE downloads");
    })();
    </script></body></html>
    """

    private func capture(_ app: XCUIApplication, _ name: String) { attachScreenshot(prefix: "downloadguard", name) }

    private func log(_ line: String) { logProbeLine(tag: "DOWNLOADGUARD", line) }
}
