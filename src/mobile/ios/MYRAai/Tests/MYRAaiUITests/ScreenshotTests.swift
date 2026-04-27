import XCTest

/// Captures App Store screenshots by driving a full login flow and photographing
/// three key screens.  Skipped silently when credentials are absent (local dev).
///
/// In CI the `screenshots` Codemagic workflow passes two env vars:
///   TEST_LOGIN_EMAIL  — reviewer account email
///   TEST_LOGIN_OTP    — static OTP for that account
///   SCREENSHOT_OUTPUT_DIR — Mac-side path where PNGs are written
///
/// PNGs are also attached as XCTAttachments (lifetime = keepAlways) so they
/// appear in the Xcode test report and in the Codemagic build artefacts.
final class ScreenshotTests: XCTestCase {

    private var loginEmail: String {
        ProcessInfo.processInfo.environment["TEST_LOGIN_EMAIL"] ?? ""
    }
    private var loginOTP: String {
        ProcessInfo.processInfo.environment["TEST_LOGIN_OTP"] ?? ""
    }
    private var outputDir: String {
        ProcessInfo.processInfo.environment["SCREENSHOT_OUTPUT_DIR"]
            ?? (NSTemporaryDirectory() + "myra_screenshots")
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        try? FileManager.default.createDirectory(
            atPath: outputDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    // MARK: - Main capture test

    func test_capture_app_store_screenshots() throws {
        guard !loginEmail.isEmpty, !loginOTP.isEmpty else {
            throw XCTSkip("TEST_LOGIN_EMAIL / TEST_LOGIN_OTP not set — screenshot capture skipped")
        }

        let app = XCUIApplication()
        app.launch()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "WebView did not appear")

        // 1 — Login screen
        let emailMethodBtn = webView.buttons
            .matching(NSPredicate(format: "label CONTAINS 'Email code'"))
            .firstMatch
        XCTAssertTrue(emailMethodBtn.waitForExistence(timeout: 30),
                      "Login page did not render")
        capture("01_login")

        // Proceed through the login flow
        emailMethodBtn.tap()

        let emailField = webView.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "Email field not found")
        emailField.tap()
        emailField.typeText(loginEmail)

        let sendBtn = webView.buttons
            .matching(NSPredicate(format: "label CONTAINS 'Send code'"))
            .firstMatch
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 10), "'Send code' button not found")
        sendBtn.tap()

        let codeField = webView.textFields.firstMatch
        XCTAssertTrue(codeField.waitForExistence(timeout: 30),
                      "OTP field did not appear after email submit")
        codeField.tap()
        codeField.typeText(loginOTP)

        let signInBtn = webView.buttons
            .matching(NSPredicate(format: "label CONTAINS 'Sign in'"))
            .firstMatch
        XCTAssertTrue(signInBtn.waitForExistence(timeout: 10), "'Sign in' button not found")
        signInBtn.tap()

        // 2 — Chat / main screen
        let navBtn = webView.buttons["Open navigation menu"]
        XCTAssertTrue(navBtn.waitForExistence(timeout: 30),
                      "Dashboard did not appear after login")
        // Brief settle for any loading spinners to clear
        _ = XCTWaiter.wait(for: [expectation(description: "settle")], timeout: 2)
        capture("02_chat")

        // 3 — Sidebar / navigation drawer
        navBtn.tap()
        _ = webView.staticTexts.firstMatch.waitForExistence(timeout: 5)
        capture("03_sidebar")
    }

    // MARK: - Helpers

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        if let data = screenshot.image.pngData() {
            try? data.write(to: url)
        }
    }
}
