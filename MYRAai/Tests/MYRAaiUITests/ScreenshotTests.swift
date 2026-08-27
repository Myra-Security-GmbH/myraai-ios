import XCTest

/// App Store screenshot capture. Logs in (TEST_LOGIN_EMAIL/OTP), drives the
/// SCREENSHOT_MODE WebView against the LIVE web, and photographs the three
/// deterministic consumer screens of /easy:
///   01_hero          — the empty hero (greeting suppressed → "How can I help today?")
///   02_model_picker  — the Auto / model-choice popover
///   03_pii_masking   — the "Preview masking" modal with 2 names redacted
///
/// The capture account (apple-review, a member) logs straight into /easy and is
/// seeded with 2 custom PII keywords (Sarah Johnson, Michael Chen) so the masking
/// modal shows real redactions. The conversation shot is deferred.
///
/// Robustness: EVERY interaction is guarded on existence — a tap/typeText on a
/// missing element throws and aborts the whole test even with
/// continueAfterFailure, so we never call them blind. The hero is captured
/// unconditionally; if anything upstream went wrong the hero PNG still shows the
/// actual on-screen state, which is the diagnostic. A loud final tally fails
/// listing any shot that didn't get captured.
///
/// Credentials arrive via env or the /tmp sidecar the Codemagic `screenshots`
/// workflow writes. Skipped silently when absent (local dev).
final class ScreenshotTests: XCTestCase {

    private struct Creds {
        let email: String
        let otp: String
        let outputDir: String
    }

    private func loadCreds() -> Creds? {
        let env = ProcessInfo.processInfo.environment
        if let email = env["TEST_LOGIN_EMAIL"], !email.isEmpty,
           let otp   = env["TEST_LOGIN_OTP"],   !otp.isEmpty {
            let dir = env["SCREENSHOT_OUTPUT_DIR"] ?? (NSTemporaryDirectory() + "myra_screenshots")
            return Creds(email: email, otp: otp, outputDir: dir)
        }
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
        continueAfterFailure = true
        if let creds = loadCreds() {
            try? FileManager.default.createDirectory(
                atPath: creds.outputDir, withIntermediateDirectories: true, attributes: nil)
        }
    }

    // MARK: - Main capture test

    func test_capture_app_store_screenshots() throws {
        guard let creds = loadCreds() else {
            throw XCTSkip("Credentials not available (\(credsDiagnostic())) — set TEST_LOGIN_EMAIL/OTP or run the screenshots workflow")
        }

        let app = XCUIApplication()
        app.launchEnvironment["SCREENSHOT_MODE"] = "1"
        app.launch()

        let webView = app.webViews.firstMatch
        _ = webView.waitForExistence(timeout: 30)

        // Auto-accept the OS push dialog so it doesn't occlude the UI.
        let allowPush = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allowPush.waitForExistence(timeout: 5) { allowPush.tap() }

        // ── Login (every step guarded) ───────────────────────────────────────
        tapIfPresent(button(webView, contains: "Email code"), timeout: 30)
        typeIfPresent(webView.textFields.firstMatch, creds.email, timeout: 10)
        tapIfPresent(button(webView, contains: "Send code"), timeout: 10)

        // OTP entry — ROBUST (AGF-1989). A single typeText into the web 6-digit field works first
        // try on iPhone but does NOT persist on iPad (the field stays empty, SIGN IN disabled), so
        // the code + submit are RETRIED until the authed hero is actually reached. On retry the field
        // is re-focused via a gesture tap anchored on the exposed "6-digit code" label — an element
        // .tap() does not reliably focus the web input on iPad (WebFlow v6 rule 3), a gesture tap
        // does. screenshot-open-picker exists ONLY on the authed /easy hero (never on the login/OTP
        // wall), so it is both the loop's success signal and the reachedApp value asserted loudly
        // at the end (a login that never lands must RED the build, not ship a login-wall shot).
        let otpField = webView.textFields.firstMatch
        _ = otpField.waitForExistence(timeout: 30)
        let codeLabel = anyLabeled(in: webView, "6-digit code")
        var reachedApp = false
        for attempt in 1...3 {
            if attempt == 1 {
                if otpField.exists { otpField.tap() }        // proven iPhone path, unchanged
            } else if codeLabel.exists {
                tapBelow(codeLabel, dy: 70)                  // stronger gesture-tap focus on retry (iPad)
            } else if otpField.exists {
                otpField.tap()
            }
            settle(0.6)
            if otpField.exists { otpField.typeText(creds.otp) }
            settle(0.8)
            tapIfPresent(button(webView, contains: "Sign in"), timeout: 8)
            if webView.buttons["screenshot-open-picker"].waitForExistence(timeout: 20) { reachedApp = true; break }
            NSLog("SHOTLOG: login attempt \(attempt) didn't reach the authed app — re-entering the 6-digit code")
            settle(2)
        }
        tapIfPresent(button(webView, contains: "Got it"), timeout: 6)
        // Composer autofocus is suppressed in screenshot mode (no soft keyboard),
        // so just let any first-boot iOS system banner ("Apple Intelligence")
        // auto-dismiss before the hero capture.
        settle(7)

        // ── 01 — Hero (unconditional) ────────────────────────────────────────
        capture("01_hero", to: creds.outputDir)

        // ── 02 — Model picker ────────────────────────────────────────────────
        // Dedicated screenshot-mode trigger (the real "Auto" pill isn't surfaced
        // to XCUITest); opens the model popover via setModelOpen.
        if tapIfPresent(webView.buttons["screenshot-open-picker"], timeout: 8) {
            settle(1.5)
            capture("02_model_picker", to: creds.outputDir)
            // Dismiss the popover by tapping a neutral spot up top.
            webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.10)).tap()
            settle(1)
        } else {
            NSLog("SHOTLOG: 02 skipped — screenshot-open-picker not found")
        }

        // ── 03 — PII masking preview ─────────────────────────────────────────
        let ta = webView.textViews.firstMatch
        if ta.waitForExistence(timeout: 8) {
            ta.tap()
            ta.typeText("Please draft a short email to Sarah Johnson and Michael Chen about the Q3 roadmap meeting on Friday.")
            settle(1)
            if tapIfPresent(button(webView, contains: "Preview masking"), timeout: 10) {
                settle(2.5)
                capture("03_pii_masking", to: creds.outputDir)
                // Close the masking modal before the conversation step. Tap "Close"
                // (never "Looks good — send", which would actually send).
                tapIfPresent(button(webView, contains: "Close"), timeout: 4)
                settle(1)
            } else {
                NSLog("SHOTLOG: 03 skipped — Preview masking link not found")
            }
        } else {
            NSLog("SHOTLOG: 03 skipped — composer textarea not found")
        }

        // ── 04 — Conversation (real answer) ──────────────────────────────────
        // Sends a curated prompt and captures the streamed answer. Done LAST
        // because it navigates the hero into a conversation. The trigger replaces
        // the draft (composerInputChange), so any lingering PII text is overwritten.
        if tapIfPresent(webView.buttons["screenshot-send-demo"], timeout: 8) {
            // Wait for the answer to stream in (no reliable stream-done signal in
            // XCUITest, so a generous fixed wait).
            settle(24)
            capture("04_conversation", to: creds.outputDir)
        } else {
            NSLog("SHOTLOG: 04 skipped — screenshot-send-demo not found")
        }

        // Best-effort capture tool: log the tally (don't fail the build) so a
        // green build publishes whatever was captured and the PNGs can be reviewed.
        for shot in ["01_hero", "02_model_picker", "03_pii_masking", "04_conversation"] {
            let path = URL(fileURLWithPath: creds.outputDir).appendingPathComponent("\(shot).png").path
            NSLog("SHOTLOG: \(shot) captured=\(FileManager.default.fileExists(atPath: path))")
        }

        // FAIL LOUDLY (this was a silent green): if login never reached the authed hero, 01_hero is
        // the login wall and 02-04 were skipped — the App-Store screenshots are worthless and must
        // NOT be published. continueAfterFailure kept the diagnostic captures/attachments above; now
        // red the build so matcher-vs-label drift is caught here instead of shipped to the store.
        XCTAssertTrue(reachedApp,
                      "login round-trip FAILED — never reached the authed /easy hero (01_hero shows the "
                      + "login wall; shots 02-04 skipped). Most likely the login button labels drifted "
                      + "vs the matchers in this file (e.g. an app-wide text-transform changing the "
                      + "WebKit accessibility name).")
    }

    // MARK: - Virtual-keyboard capture (AGF-1937)

    /// Proves the Codemagic simulator raises the ON-SCREEN software keyboard — the capability the
    /// separate GitHub-Actions Appium rig existed for — and captures the keyboard-open /easy states:
    ///   kb_01_composer_keyboard — composer focused, keyboard up. Also the visual verification of the
    ///                             AGF-1937 accessory-bar kill (WebView.swift): NO prev/next+Done row
    ///                             may sit between the composer and the keyboard.
    ///   kb_02_model_picker      — the picker opened from the keyboard-open state (keyboard closes).
    /// HARD-asserts the keyboard appears: a sim that silently attaches a hardware keyboard must FAIL
    /// the build, not ship misleading "all clear" screenshots. The keyboard-check workflow also
    /// writes ConnectHardwareKeyboard=false before boot.
    func test_capture_keyboard_screens() throws {
        guard let creds = loadCreds() else {
            throw XCTSkip("Credentials not available (\(credsDiagnostic())) — set TEST_LOGIN_EMAIL/OTP or run the keyboard-check workflow")
        }

        // Shared v6 flow (WebFlow.swift): element-anchored taps, gesture-raised keyboard, Return
        // submits. loginRoundTrip hard-requires the SOFTWARE keyboard on both input taps — the
        // capability this workflow exists to prove.
        let app = XCUIApplication()
        app.launchArguments += standardLaunchArgs(authViaCiSession: true)  // AGF-1948: boot authed when the grant is wired; falls back to real login otherwise
        app.launch()
        let webView = app.webViews.firstMatch
        _ = webView.waitForExistence(timeout: 30)
        let allowPush = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allowPush.waitForExistence(timeout: 5) { allowPush.tap() }

        XCTAssertTrue(ensureLoggedIn(app: app, webView: webView, email: creds.email, otp: creds.otp),
                      "could not reach the authenticated app — grep WEBFLOW in the log for the failing step")
        dismissFirstRunDisclaimer(app: app, webView: webView)

        // Post-login /easy accessibility audit — LOG-ONLY baseline (the login audit is the gated
        // one; gate this too once its baseline is triaged). Discovery channel: contrast/labels/hit
        // regions across the whole authed hero.
        try? runA11yAudit(app, label: "easy", gate: false)

        // ── kb_01 — composer focused, software keyboard UP. Also the visual verification of the
        // accessory-bar kill (WebView.swift AccessoryBarKiller): NO prev/next+Done row may sit
        // between the composer card and the QWERTY. ────────────────────────────────────────────
        XCTAssertTrue(focusComposer(app: app, webView: webView),
                      "software keyboard did not appear after tapping the /easy composer")
        settleWait(2) // keyboard animation + the web app's dock re-layout
        capture("kb_01_composer_keyboard", to: creds.outputDir)

        // ── kb_02 — model picker from the keyboard-open state (best-effort: the Auto pill is not
        // exposed; its toolbar row sits at the docked card's bottom band). ──────────────────────
        webView.coordinate(withNormalizedOffset: CGVector(dx: 0.145, dy: 0.42)).tap()
        settleWait(3) // keyboard close animation + the AGF-1937 re-clamp poll re-growing the picker
        capture("kb_02_model_picker", to: creds.outputDir)

        for shot in ["kb_01_composer_keyboard", "kb_02_model_picker"] {
            let path = URL(fileURLWithPath: creds.outputDir).appendingPathComponent("\(shot).png").path
            NSLog("SHOTLOG: \(shot) captured=\(FileManager.default.fileExists(atPath: path))")
        }
    }

    /// German + dark capture (AGF-1940 class): the de CTA labels are much wider than the English
    /// ones ("STOPPEN & SENDEN" vs "STOP & SEND") and once painted past the send button's bounds at
    /// 390-402pt widths. This capture documents the de composer with the keyboard open — the
    /// AGF-1940 containment fix must show SENDEN inside its button. Dark appearance comes from the
    /// workflow (simctl ui appearance dark), matching the main reporter's scheme.
    func test_capture_de_composer_keyboard() throws {
        guard let creds = loadCreds() else {
            throw XCTSkip("Credentials not available (\(credsDiagnostic())) — run via the keyboard-check workflow")
        }
        let app = XCUIApplication()
        app.launchArguments += standardLaunchArgs(languages: "(de)", locale: "de_DE", authViaCiSession: true)
        app.launch()
        let webView = app.webViews.firstMatch
        _ = webView.waitForExistence(timeout: 30)
        let allowPush = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allowPush.waitForExistence(timeout: 5) { allowPush.tap() }

        XCTAssertTrue(ensureLoggedIn(app: app, webView: webView, email: creds.email, otp: creds.otp, anchors: .de),
                      "de login/auth failed — grep WEBFLOW in the log")
        dismissFirstRunDisclaimer(app: app, webView: webView, anchors: .de)

        XCTAssertTrue(focusComposer(app: app, webView: webView),
                      "software keyboard did not appear on the de composer")
        settleWait(2)
        capture("kb_de_01_composer_senden", to: creds.outputDir)
        NSLog("SHOTLOG: kb_de_01_composer_senden captured=true (verify SENDEN stays inside its button)")
    }

    // MARK: - Scenario debug capture (AGF-1991)

    /// FAST, focused debug target for ONE scenario: the /easy CONVERSATION view with the soft keyboard
    /// open, where the status bar collided with scrolled thread content in the App Store shot. That
    /// class (AGF-1937/1939 keyboard-viewport safe-area) is UNREPRODUCIBLE in headless WebKit
    /// (keyboardViewport.ts says so), so a real-simulator capture is the only faithful repro. Its own
    /// `kb-debug` Codemagic workflow runs JUST this test against INT (ai-int.myra.eu — where SPA fixes
    /// land pre-prod), so a fix can be deployed to int and re-checked in one short build instead of the
    /// full keyboard/screenshots suite. Boots authed via the CI session (AGF-1948), sends one short turn
    /// so the thread has content, re-opens the keyboard, brings the thread TOP into view (where the
    /// first message meets the status bar), and captures kb_conversation_overlap for inspection.
    func test_capture_kb_conversation_overlap() throws {
        guard let creds = loadCreds() else {
            throw XCTSkip("Credentials not available (\(credsDiagnostic())) — run the kb-debug workflow")
        }
        let app = XCUIApplication()
        app.launchArguments += standardLaunchArgs(authViaCiSession: true)  // -MyraBaseURL(int) + CI session
        app.launch()
        let webView = app.webViews.firstMatch
        _ = webView.waitForExistence(timeout: 30)
        let allowPush = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allowPush.waitForExistence(timeout: 5) { allowPush.tap() }

        // DEBUG target — best-effort, never asserts: we want SCREENSHOTS to inspect, not a red build.
        // Capture the boot state UNCONDITIONALLY first (login wall? authed hero? blank?), so a failed
        // auth/nav is diagnosable from the shot itself.
        settleWait(6)
        capture("kb_00_boot", to: creds.outputDir)

        // Dismiss the first-run "Welcome — a quick look around" walkthrough overlay — it covers the
        // /easy hero + composer on the fresh ci-ios identity (which re-onboards every run; the App
        // Store apple-review account had already onboarded, so the other workflows never hit it).
        // Match the walkthrough's EXACT "Skip" button (label ==[c]) — CONTAINS[c] also matched the
        // off-screen "Skip to main content" WCAG bypass link and aborted on its non-hittable frame.
        // Guard on isHittable so a miss never aborts this best-effort debug capture.
        let skip = webView.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", "Skip")).firstMatch
        if skip.waitForExistence(timeout: 8) && skip.isHittable {
            skip.tap()
            settleWait(2)
            NSLog("SHOTLOG: dismissed the first-run walkthrough (Skip)")
        } else {
            NSLog("SHOTLOG: walkthrough Skip not hittable/absent (hittable=\(skip.exists ? String(skip.isHittable) : "absent"))")
        }

        let authed = ensureLoggedIn(app: app, webView: webView, email: creds.email, otp: creds.otp)
        NSLog("SHOTLOG: kb-debug authed=\(authed)")
        dismissFirstRunDisclaimer(app: app, webView: webView)
        settleWait(3)
        capture("kb_01_easy", to: creds.outputDir)   // the authed /easy hero, or wherever we landed

        // Reach the CONVERSATION + soft-keyboard state (best-effort; capture regardless). Use the
        // proven composer path from the main test: the composer is textViews.firstMatch — tap it (raises
        // the keyboard), type, then tap the SEND button (Enter is a newline in the composer, not send).
        let composer = webView.textViews.firstMatch
        if composer.waitForExistence(timeout: 10) {
            composer.tap()
            composer.typeText("List five quick productivity tips, one short line each.")
            settle(1)
            capture("kb_02_composed", to: creds.outputDir)   // composer filled + keyboard (diagnostic)
            // Tap the COMPOSER send (aria-label "Send message", data-cy easy-send) — NOT a bare "Send"
            // match, which caught the top-bar "Send Feedback" flag and opened the feedback modal.
            _ = tapIfPresent(button(webView, contains: "Send message"), timeout: 6)
            settleWait(26)   // let the answer stream in (no reliable stream-done signal in XCUITest)
            capture("kb_03_after_send", to: creds.outputDir)   // the conversation (keyboard may have closed)
            // Re-open the keyboard on the conversation composer — the keyboard-open conversation is the
            // exact state where prod showed the status bar over the (scrolled) thread top.
            composer.tap()
            settleWait(3)
        } else {
            NSLog("SHOTLOG: composer textView not found — capturing the current state anyway")
        }
        capture("kb_conversation_overlap", to: creds.outputDir)
        for shot in ["kb_00_boot", "kb_01_easy", "kb_conversation_overlap"] {
            let p = URL(fileURLWithPath: creds.outputDir).appendingPathComponent("\(shot).png").path
            NSLog("SHOTLOG: \(shot) captured=\(FileManager.default.fileExists(atPath: p))")
        }
    }

    // MARK: - Helpers

    private func button(_ webView: XCUIElement, contains text: String) -> XCUIElement {
        // CONTAINS[c] (case-insensitive): AGF-1866 applied `text-transform: uppercase` to the app's
        // buttons, and WebKit exposes the TRANSFORMED text as the accessibility label XCUITest reads
        // (so "Continue with Email code" surfaces as "CONTINUE WITH EMAIL CODE"). A case-SENSITIVE
        // match silently found nothing and the whole login no-op'd — see the loud reachedApp assert.
        webView.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// Tap only if the element materialises within `timeout`. Never throws.
    @discardableResult
    private func tapIfPresent(_ el: XCUIElement, timeout: TimeInterval) -> Bool {
        guard el.waitForExistence(timeout: timeout) else { return false }
        el.tap()
        return true
    }

    /// Tap + type only if the field materialises. Never throws.
    private func typeIfPresent(_ field: XCUIElement, _ text: String, timeout: TimeInterval) {
        guard field.waitForExistence(timeout: timeout) else { return }
        field.tap()
        field.typeText(text)
    }

    private func settle(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [expectation(description: "settle")], timeout: seconds)
    }

    /// Dismiss any iOS system notification banner (e.g. the first-boot "Apple
    /// Intelligence" onboarding) so it doesn't pollute a capture. Best-effort.
    private func dismissTopBanner() {
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = sb.otherElements
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "intelligence", "notification"))
            .firstMatch
        if banner.waitForExistence(timeout: 0.5) {
            banner.swipeUp()
            settle(0.6)
        }
    }

    private func capture(_ name: String, to outputDir: String) {
        dismissTopBanner()
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        if let data = screenshot.image.pngData() { try? data.write(to: url) }
    }
}
