import XCTest

/// Regression guards for the iOS simplification pass.
///
/// These are the DETERMINISTIC, self-contained guards that gate the release
/// build: native behaviour only, no network, no prod SPA, no login — so they
/// never flake on prod availability. Prod-SPA-coupled checks (login page,
/// privacy link, login round-trip) live in LoginTests, which runs as a
/// non-blocking prod-smoke lane. Every test here except T-1 launches with
/// -MyraUITestSuppressPushPrompt so only T-1 triggers the once-per-install
/// push dialog (order-independent).
final class RegressionGuards: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func waitForWebView(_ app: XCUIApplication, timeout: TimeInterval = 30) -> XCUIElement {
        let webView = app.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: timeout),
            "WebView did not appear within \(Int(timeout))s"
        )
        return webView
    }

    /// T-1: First launch shows the system push-permission dialog.
    /// Catches: re-introduction of `.provisional` in `requestAuthorization` options
    /// (the bug that started the simplification pass — provisional silently routes
    /// pushes to Quiet Delivery so testers never see a banner).
    ///
    /// Relies on Codemagic providing a clean simulator state per run — there is
    /// no public API to reset notification permissions from a UI test
    /// (XCUIProtectedResource has no .userNotifications case).
    func test_first_launch_shows_push_permission_dialog() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        XCTAssertTrue(
            allow.waitForExistence(timeout: 10),
            "System notifications permission dialog did not appear within 10s — `.provisional` may have been re-introduced"
        )
        allow.tap()
    }

    // T-2 (Login page shows a Privacy Policy link) moved to LoginTests — it
    // depends on the prod SPA rendering, so it belongs in the non-blocking
    // prod-smoke lane, not the deterministic release gate.

    /// T-3: the privacy shield renders and fully covers the window.
    /// Catches: the shield view/accessibility id breaking, or the shield no
    /// longer covering content — it's what hides chat from the app-switcher
    /// snapshot when the app is backgrounded.
    ///
    /// Why forced, not a real background cycle: the shield is set on `.inactive`
    /// and hidden again on `.active`, and a foreground XCUITest cannot query a
    /// backgrounded app — so observing it after a real background/return is
    /// inherently racy (it was the reason the earlier version only ever
    /// "passed" by being skipped). We force it via a DEBUG launch hook and
    /// assert the rendered result deterministically. The .inactive trigger and
    /// the instant-insertion timing are not XCUITest-observable.
    func test_privacy_shield_renders_and_covers_window() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-MyraUITestForceShield", "-MyraUITestSuppressPushPrompt"]
        app.launch()

        // Query by identifier across any element type — the shield is an
        // accessibilityElement(), but which concrete XCUI type it surfaces as
        // can vary, so don't assume `.otherElements`.
        let shield = app.descendants(matching: .any)["myra-privacy-shield"]
        XCTAssertTrue(
            shield.waitForExistence(timeout: 10),
            "Privacy shield did not render when forced — view or accessibility id may have broken"
        )

        // Existence isn't enough — it must actually cover the window.
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "no app window to compare against")
        XCTAssertTrue(
            shield.frame.height >= window.frame.height - 2 &&
            shield.frame.width >= window.frame.width - 2,
            "Privacy shield does not cover the full window (shield \(shield.frame) vs window \(window.frame))"
        )
    }

    /// T-4: tapping a file input opens WebKit's native upload sheet.
    /// Catches: the silent-attachment-drop class (AGF-198) — a custom
    /// runOpenPanel override that handed WebKit unreadable security-scoped URLs
    /// so the attachment vanished with no error. We rely on WebKit's built-in
    /// WKFileUploadPanel instead.
    ///
    /// Hermetic by design: the regression is native and origin/auth-independent,
    /// so we drive a bare <input type=file> served by a DEBUG-only launch hook
    /// (`-MyraUITestLocalFileInput`) — no login, no network, fully deterministic.
    /// The /easy composer's attach affordance is covered by the web E2E suite.
    func test_attach_opens_native_upload_sheet() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-MyraUITestLocalFileInput", "-MyraUITestSuppressPushPrompt"]
        app.launch()
        let webView = waitForWebView(app)

        // A bare <input type=file> renders as the page's only button in WebKit.
        let fileInput = webView.buttons.firstMatch
        XCTAssertTrue(
            fileInput.waitForExistence(timeout: 15),
            "file input did not render in the DEBUG test page — launch hook may be missing from the build"
        )
        fileInput.tap()

        // WebKit presents WKFileUploadPanel as an action sheet. Assert it
        // appeared — key on "Photo Library" (unique to the sheet) or the sheet
        // element itself; we avoid "Choose File" because the web input button
        // carries that same label. "Take Photo" is absent on the simulator.
        let sheet = app.sheets.firstMatch
        let photoLibrary = app.buttons["Photo Library"]
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 5) || photoLibrary.waitForExistence(timeout: 5),
            "WebKit native upload sheet did not appear after tapping the file input — silent-drop regression (AGF-198)"
        )
    }
}
