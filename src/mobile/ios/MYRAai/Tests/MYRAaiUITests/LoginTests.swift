import XCTest

/// End-to-end login smoke test.
///
/// Validates the entire user-visible product path: form rendering, /otp/request,
/// /otp/verify, session creation, post-login navigation.
///
/// Credentials are NEVER hardcoded; they come in via environment variables that
/// Codemagic injects from its "test" CI/CD variable group at `xcodebuild test`
/// invocation time. Local runs without those env vars `XCTSkip` the auth tests
/// (so a developer running tests locally never accidentally attempts to log in).
///
/// Tests run against the production WebView URL the app boots into. The
/// `apple-review@myrasecurity.com` user has a static OTP hash on the backend
/// (see migration 0011_static_otp_for_reviewer.sql) so a fixed code can be
/// re-used here without an email round trip.
final class LoginTests: XCTestCase {

    // MARK: - Credentials (read from CI env, never persisted)

    private var loginEmail: String {
        ProcessInfo.processInfo.environment["TEST_LOGIN_EMAIL"] ?? ""
    }
    private var loginOTP: String {
        ProcessInfo.processInfo.environment["TEST_LOGIN_OTP"] ?? ""
    }

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Wait for the WebView itself to render (not its contents). Returns the
    /// WebView element so callers can scope further queries.
    private func waitForWebView(_ app: XCUIApplication, timeout: TimeInterval = 30) -> XCUIElement {
        let webView = app.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: timeout),
            "WebView did not appear within \(Int(timeout))s — app boot or WKWebView creation failed"
        )
        return webView
    }

    /// Try several accessibility identifiers in order — useful because iOS
    /// exposes WebView form elements under different keys depending on the
    /// HTML markup (label-for, aria-label, placeholder, id).
    private func firstFound(
        in webView: XCUIElement,
        kind: ElementKind,
        candidates: [String],
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        for candidate in candidates {
            let element: XCUIElement
            switch kind {
            case .button:    element = webView.buttons[candidate]
            case .textField: element = webView.textFields[candidate]
            case .otherElement: element = webView.otherElements[candidate]
            }
            if element.waitForExistence(timeout: timeout) {
                return element
            }
        }
        return nil
    }

    private enum ElementKind { case button, textField, otherElement }

    // MARK: - Tests

    /// L-1 / P0-1: app launches, WebView loads, login page renders.
    /// No credentials needed — runs always.
    func test_app_launches_and_login_page_renders() throws {
        let app = XCUIApplication()
        app.launch()

        let webView = waitForWebView(app)

        let emailMethodBtn = firstFound(
            in: webView,
            kind: .button,
            candidates: ["Continue with Email code"],
            timeout: 30
        )
        XCTAssertNotNil(
            emailMethodBtn,
            "Login page did not render the 'Continue with Email code' button — frontend bundle / network / auth route is broken"
        )
    }

    /// L-2: full login round-trip with the static reviewer credentials.
    /// Validates the entire user-visible product path: form rendering,
    /// /otp/request, /otp/verify, session creation, post-login navigation.
    func test_login_with_static_credentials_lands_on_dashboard() throws {
        guard !loginEmail.isEmpty, !loginOTP.isEmpty else {
            throw XCTSkip("TEST_LOGIN_EMAIL / TEST_LOGIN_OTP not set — login round-trip skipped")
        }

        let app = XCUIApplication()
        app.launch()
        let webView = waitForWebView(app)

        // Step 1: choose email-OTP method
        guard let emailMethodBtn = firstFound(
            in: webView,
            kind: .button,
            candidates: ["Continue with Email code"],
            timeout: 30
        ) else {
            XCTFail("Email-OTP method button not found")
            return
        }
        emailMethodBtn.tap()

        // Step 2: type email and submit
        guard let emailField = firstFound(
            in: webView,
            kind: .textField,
            candidates: ["Email address", "admin@example.com", "login-email"]
        ) else {
            XCTFail("Email input field not found")
            return
        }
        emailField.tap()
        emailField.typeText(loginEmail)

        guard let sendCodeBtn = firstFound(
            in: webView,
            kind: .button,
            candidates: ["Send code", "Sending…"]
        ) else {
            XCTFail("'Send code' button not found")
            return
        }
        sendCodeBtn.tap()

        // Step 3: type the static OTP and submit
        guard let codeField = firstFound(
            in: webView,
            kind: .textField,
            candidates: ["6-digit code", "123456", "login-code"],
            timeout: 30
        ) else {
            XCTFail("OTP input field did not appear after email submit — /otp/request likely failed")
            return
        }
        codeField.tap()
        codeField.typeText(loginOTP)

        guard let signInBtn = firstFound(
            in: webView,
            kind: .button,
            candidates: ["Sign in", "Verifying…"]
        ) else {
            XCTFail("'Sign in' button not found")
            return
        }
        signInBtn.tap()

        // Step 4: assert we reached the dashboard.
        // The mobile sidebar exposes an "Open navigation menu" hamburger button;
        // its presence is a reliable signal the post-login app shell mounted.
        let dashboardSignal = firstFound(
            in: webView,
            kind: .button,
            candidates: ["Open navigation menu"],
            timeout: 30
        )
        XCTAssertNotNil(
            dashboardSignal,
            "Did not reach the dashboard after submitting the OTP — /otp/verify likely failed or static_otp_hash regression"
        )
    }
}
