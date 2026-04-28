import XCTest

/// Captures App Store screenshots by driving a full login flow and photographing
/// three key screens.  Skipped silently when credentials are absent (local dev).
///
/// In CI the `screenshots` Codemagic workflow writes a JSON sidecar file at
/// /tmp/myra_screenshot_creds.json before invoking xcodebuild, because Xcode 26
/// does not forward TEST_RUNNER_* build settings or shell env vars into the
/// XCUITest runner process.  The sidecar format is:
///   {"email":"...", "otp":"...", "output_dir":"..."}
///
/// Sidebar navigation: the hamburger button uses position:fixed and was previously
/// portaled to document.body, which prevented XCUITest touch events from bubbling
/// through the React root and firing the onClick.  The button is now kept inside
/// the React root so coordinate().tap() correctly triggers React's event delegation.
final class ScreenshotTests: XCTestCase {

    private struct Creds {
        let email: String
        let otp: String
        let outputDir: String
    }

    private func loadCreds() -> Creds? {
        // 1. Shell environment (works when -testenv or TEST_RUNNER_ forwarding is available)
        let env = ProcessInfo.processInfo.environment
        if let email = env["TEST_LOGIN_EMAIL"], !email.isEmpty,
           let otp   = env["TEST_LOGIN_OTP"],   !otp.isEmpty {
            let dir = env["SCREENSHOT_OUTPUT_DIR"] ?? (NSTemporaryDirectory() + "myra_screenshots")
            return Creds(email: email, otp: otp, outputDir: dir)
        }
        // 2. Sidecar file written by the Codemagic shell script
        guard let data = FileManager.default.contents(atPath: "/tmp/myra_screenshot_creds.json"),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let email = obj["email"], !email.isEmpty,
              let otp   = obj["otp"],   !otp.isEmpty else { return nil }
        let dir = obj["output_dir"] ?? (NSTemporaryDirectory() + "myra_screenshots")
        return Creds(email: email, otp: otp, outputDir: dir)
    }

    private func credsDiagnostic() -> String {
        let env = ProcessInfo.processInfo.environment
        let hasEnv = !(env["TEST_LOGIN_EMAIL"] ?? "").isEmpty
        let hasSidecar = FileManager.default.fileExists(atPath: "/tmp/myra_screenshot_creds.json")
        return "env-vars:\(hasEnv) sidecar:\(hasSidecar)"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let creds = loadCreds() {
            try? FileManager.default.createDirectory(
                atPath: creds.outputDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
    }

    // MARK: - Main capture test

    func test_capture_app_store_screenshots() throws {
        guard let creds = loadCreds() else {
            throw XCTSkip("Credentials not available (\(credsDiagnostic())) — set TEST_LOGIN_EMAIL/OTP or run the screenshots workflow")
        }

        let app = XCUIApplication()
        app.launch()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "WebView did not appear")

        // 1 — Login screen
        // waitForExistence is satisfied before the WebView has finished painting.
        // The extra 2 s lets React complete its render so the screenshot is sharp.
        let emailMethodBtn = webView.buttons
            .matching(NSPredicate(format: "label CONTAINS 'Email code'"))
            .firstMatch
        XCTAssertTrue(emailMethodBtn.waitForExistence(timeout: 30),
                      "Login page did not render")
        _ = XCTWaiter.wait(for: [expectation(description: "login-paint")], timeout: 2)
        capture("01_login", to: creds.outputDir)

        // — Login flow —
        emailMethodBtn.tap()

        let emailField = webView.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "Email field not found")
        emailField.tap()
        emailField.typeText(creds.email)

        let sendBtn = webView.buttons
            .matching(NSPredicate(format: "label CONTAINS 'Send code'"))
            .firstMatch
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 10), "'Send code' button not found")
        sendBtn.tap()

        let codeField = webView.textFields.firstMatch
        XCTAssertTrue(codeField.waitForExistence(timeout: 30),
                      "OTP field did not appear after email submit")
        codeField.tap()
        codeField.typeText(creds.otp)

        let signInBtn = webView.buttons
            .matching(NSPredicate(format: "label CONTAINS 'Sign in'"))
            .firstMatch
        XCTAssertTrue(signInBtn.waitForExistence(timeout: 10), "'Sign in' button not found")
        signInBtn.tap()

        // — Post-login: navigate to Chat —
        let navBtn = webView.buttons["Open navigation menu"]
        XCTAssertTrue(navBtn.waitForExistence(timeout: 30),
                      "Dashboard did not appear after login")

        // Open sidebar.
        // The hamburger has position:fixed and reports isHittable=false due to WKWebView
        // hit-test handling for fixed-position elements.  coordinate().tap() bypasses
        // the hittability check and synthesises a touch event.  Because the button is now
        // inside the React root (not portaled to document.body), the touch event bubbles
        // through #root and React's event delegation fires the onClick → setMobileOpen(true).
        navBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Confirm sidebar opened: hamburger gets display:none when mobileOpen=true.
        XCTAssertTrue(navBtn.waitForNonExistence(timeout: 5),
                      "Sidebar did not open — hamburger still visible after tap")

        // Allow the 0.25 s CSS slide-in transition to finish before capturing.
        _ = XCTWaiter.wait(for: [expectation(description: "sidebar-open")], timeout: 1)

        // 3 — Sidebar open
        capture("03_sidebar", to: creds.outputDir)

        // Navigate to Chat.
        // nav-item has width:100% (full 240pt) — tap at sidebar horizontal centre (x=120).
        let chatLink = webView.links
            .matching(NSPredicate(format: "label == 'Chat'"))
            .firstMatch
        XCTAssertTrue(chatLink.waitForExistence(timeout: 5), "Chat link not found in sidebar")
        let chatLinkY = chatLink.frame.midY
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 120, dy: chatLinkY))
            .tap()

        // 2 — Chat screen
        XCTAssertTrue(navBtn.waitForExistence(timeout: 15), "Chat page did not load")
        _ = XCTWaiter.wait(for: [expectation(description: "chat-paint")], timeout: 2)
        capture("02_chat", to: creds.outputDir)
    }

    // MARK: - Helpers

    private func capture(_ name: String, to outputDir: String) {
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
