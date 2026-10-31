import XCTest
import Foundation

/// End-to-end login smoke test.
///
/// Validates the entire user-visible product path: form rendering, /otp/request,
/// /otp/verify, session creation, post-login navigation.
///
/// Credentials are NEVER hardcoded. Codemagic's "test" CI/CD variable group sets
/// TEST_LOGIN_EMAIL / TEST_LOGIN_OTP in the build SHELL, but `xcodebuild test`
/// does NOT forward shell env into the XCUITest *runner* process — so the
/// workflow also writes a /tmp sidecar that `loadCreds()` reads (env first, then
/// the sidecar). Local runs without either `XCTSkip` the auth tests (so a
/// developer never accidentally attempts a real login).
///
/// Tests run against the production WebView URL the app boots into. The
/// `apple-review@myrasecurity.com` user has a static OTP hash on the backend
/// (see migration 0011_static_otp_for_reviewer.sql) so a fixed code can be
/// re-used here without an email round trip.
final class LoginTests: XCTestCase {

    // MARK: - Credentials (read from CI, never persisted)

    private struct Creds { let email: String; let otp: String }

    /// Env first, then the /tmp sidecar the Codemagic workflow writes (the
    /// simulator shares the host /tmp, so the runner can read it). Returns nil
    /// only when neither source has both values — i.e. a local dev run.
    private func loadCreds() -> Creds? {
        let env = ProcessInfo.processInfo.environment
        if let email = env["TEST_LOGIN_EMAIL"], !email.isEmpty,
           let otp = env["TEST_LOGIN_OTP"], !otp.isEmpty {
            return Creds(email: email, otp: otp)
        }
        guard let data = FileManager.default.contents(atPath: "/tmp/myra_test_creds.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let email = obj["email"], !email.isEmpty,
              let otp = obj["otp"], !otp.isEmpty else { return nil }
        return Creds(email: email, otp: otp)
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

    /// Launch with the push prompt suppressed (only RegressionGuards T-1 tests
    /// it; consuming it here would make T-1 flaky) and the locale forced to
    /// English so the login labels match.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // standardLaunchArgs adds -MyraBaseURL from the workflow sidecar, so the smoke targets INT
        // (fixes land there pre-prod); without a sidecar the app boots its normal prod URL.
        app.launchArguments += standardLaunchArgs()
        app.launch()
        return app
    }

    // MARK: - Tests (v6 technique — see WebFlow.swift for the Xcode 26.4 exposure rules)

    /// Login page shows a privacy link (App Store review requirement). Links survive the Xcode
    /// 26.4 exposure regression; match by CONTAINS so both "Privacy" (current footer) and the old
    /// "Privacy Policy" label pass.
    func test_login_page_shows_privacy_policy_link() throws {
        let app = launch()
        let webView = waitForWebView(app)
        XCTAssertTrue(
            anyLabeled(in: webView, "Privacy").waitForExistence(timeout: 40),
            "No privacy link/text found on the login page — SPA may have reverted or failed to render"
        )
    }

    /// L-1 / P0-1: app launches, WebView loads, login page renders. The render signal is the
    /// EXPOSED page title — buttons are invisible to XCUITest on this toolchain (WebFlow.swift).
    func test_app_launches_and_login_page_renders() throws {
        let app = launch()
        let webView = waitForWebView(app)
        XCTAssertTrue(
            anyLabeled(in: webView, "Sign in to Myra").waitForExistence(timeout: 40),
            "Login page title did not render — frontend bundle / network / auth route is broken"
        )
    }

    /// L-2: full login round-trip with the static reviewer credentials. Validates form rendering,
    /// /otp/request, /otp/verify, session creation and post-login navigation — via the shared
    /// element-anchored flow (WebFlow.loginRoundTrip), which also implicitly proves the software
    /// keyboard rises on the input taps.
    func test_login_with_static_credentials_lands_on_dashboard() throws {
        guard let creds = loadCreds() else {
            throw XCTSkip("No TEST_LOGIN_* creds (env or /tmp sidecar) — login round-trip skipped (local dev only; CI injects them)")
        }
        let app = launch()
        let webView = waitForWebView(app)
        XCTAssertTrue(
            loginRoundTrip(app: app, webView: webView, email: creds.email, otp: creds.otp),
            "Login round-trip failed — grep WEBFLOW in the log for the failing step"
        )
        XCTAssertTrue(
            postLoginSignal(in: webView),
            "Did not reach the post-login app after submitting the OTP — /otp/verify likely failed or static_otp_hash regression"
        )
    }
}
