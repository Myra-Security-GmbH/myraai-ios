import XCTest

/// AGF-1937 — accessibility audit of the live app on a real iOS simulator. XCTest's
/// performAccessibilityAudit (Xcode 15+/iOS 17+) runs Apple's audits — missing labels, contrast,
/// hit-region size, trait problems — over the CURRENT screen including the WKWebView's web content.
/// A BITV 2.0 / WCAG-relevant discovery channel none of the Linux-side suites has.
///
/// LOG-ONLY for now: every issue is NSLogged (grep A11YAUDIT in the build log) and the audit never
/// fails the build, so the first runs establish a baseline without blocking. Flip `failOnIssues`
/// once the baseline is triaged to make it a gate.
final class A11yAuditTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// Audit the login page (pre-auth — no credentials needed). The gate comes from the workflow
    /// sidecar (a11y_gate=true once the environment under test carries the AGF-1944 fix): gated,
    /// any issue fails the build; ungated, log-only baseline.
    func test_a11y_audit_login_page() throws {
        let gate = sidecarValue("a11y_gate") == "true"
        let app = XCUIApplication()
        app.launchArguments += standardLaunchArgs()
        app.launch()
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "WebView did not appear")
        XCTAssertTrue(anyLabeled(in: webView, "Sign in to Myra").waitForExistence(timeout: 40),
                      "login page never rendered — cannot audit")
        settleWait(2)
        try runA11yAudit(app, label: "login", gate: gate)
    }
}
