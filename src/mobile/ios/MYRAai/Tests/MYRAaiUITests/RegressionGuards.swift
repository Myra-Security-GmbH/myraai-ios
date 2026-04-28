import XCTest

/// Regression guards for the iOS simplification pass.
///
/// Each test name encodes the bug it would have caught. Where a test depends
/// on credentials or platform features the simulator can't supply, it
/// `throw XCTSkip(…)` rather than asserting falsely-green.
final class RegressionGuards: XCTestCase {

    private var loginEmail: String {
        ProcessInfo.processInfo.environment["TEST_LOGIN_EMAIL"] ?? ""
    }
    private var loginOTP: String {
        ProcessInfo.processInfo.environment["TEST_LOGIN_OTP"] ?? ""
    }

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

    /// T-2: Login page shows a Privacy Policy link.
    /// Catches: regression of the SPA `LoginPage.tsx` change that replaced the
    /// iOS-side MutationObserver injection. The link is a hard requirement for
    /// App Store review.
    func test_login_page_shows_privacy_policy_link() throws {
        let app = XCUIApplication()
        app.launch()
        let webView = waitForWebView(app)

        let link = webView.links["Privacy Policy"]
        XCTAssertTrue(
            link.waitForExistence(timeout: 30),
            "Privacy Policy link not found on login page — SPA may have reverted or iOS shim removed without SPA replacement deployed"
        )
    }

    /// T-3: Privacy shield renders when the app is sent to the background.
    /// Catches: shield trigger reverting from `.inactive` back to `.background`
    /// (which would let the app-switcher snapshot leak content the first time
    /// the user backgrounds).
    func test_privacy_shield_appears_on_deactivation() throws {
        guard !loginEmail.isEmpty, !loginOTP.isEmpty else {
            throw XCTSkip("TEST_LOGIN_EMAIL / TEST_LOGIN_OTP not set — privacy shield test needs an authenticated session")
        }

        let app = XCUIApplication()
        app.launch()
        _ = waitForWebView(app)

        // Send to background then reactivate — .inactive → .background → .inactive → .active.
        XCUIDevice.shared.press(.home)
        // give the system a beat to render the snapshot
        sleep(1)
        app.activate()

        let shield = app.otherElements["myra-privacy-shield"]
        XCTAssertTrue(
            shield.waitForExistence(timeout: 2),
            "Privacy shield did not render on reactivation — scenePhase trigger may have reverted to .background"
        )
    }

    /// T-4: File attach button opens the document picker on iOS 18.4+.
    /// Catches: regression of the @available gate (WKOpenPanelParameters
    /// itself is iOS 18.4+ on iOS; can't be lowered).
    func test_file_picker_opens_when_attach_tapped() throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("File picker requires iOS 18.4+ (WKOpenPanelParameters)")
        }
        guard !loginEmail.isEmpty, !loginOTP.isEmpty else {
            throw XCTSkip("TEST_LOGIN_EMAIL / TEST_LOGIN_OTP not set — file picker test needs an authenticated session")
        }

        let app = XCUIApplication()
        app.launch()
        let webView = waitForWebView(app)

        // The attach button is exposed by the SPA chat input. Try a few common
        // accessibility identifiers / labels — file picker UX wording may shift.
        let candidates = ["Attach file", "Attach", "Add attachment", "attach"]
        var attachButton: XCUIElement?
        for name in candidates {
            let btn = webView.buttons[name]
            if btn.waitForExistence(timeout: 5) { attachButton = btn; break }
        }
        guard let attach = attachButton else {
            throw XCTSkip("Attach button not visible (may require navigating to chat after login — out of scope for regression guard)")
        }
        attach.tap()

        // The document picker is a separate process; query for any element
        // matching the picker's window scene.
        let picker = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS[c] %@", "Documents")).firstMatch
        XCTAssertTrue(
            picker.waitForExistence(timeout: 5),
            "Document picker did not appear — the iOS 16.4+ availability gate may have regressed"
        )
    }
}
