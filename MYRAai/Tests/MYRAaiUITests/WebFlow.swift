import XCTest

/// AGF-1937 — the ONE implementation of the "v6 technique" for driving the live SPA inside the
/// app's WKWebView under Xcode 26.4, shared by LoginTests, ScreenshotTests and A11yAuditTests
/// (no duplicated flows). Each rule below was learned from a burned CI run:
///   1. The live SPA exposes ONLY headings/static text/links to XCUITest — no buttons, no inputs
///      ("Automation type mismatch: computed Other from legacy attributes"). Type-scoped queries
///      (.buttons/.textFields) match nothing; label queries across .any match the exposed subset.
///   2. RAW webview-normalized coordinate taps land nowhere; coordinates ANCHORED on an exposed
///      element's frame tap reliably.
///   3. Programmatic focus (autofocus) never raises the iOS keyboard — only a real gesture tap on
///      the field does. Typing goes to the focused element via app.typeText; Return submits the
///      single-input login forms.
/// Locale-dependent anchor strings for the login/hero flows. The v6 technique navigates by
/// EXPOSED labels, and those are localized — one struct per supported UI language.
struct WebAnchors {
    let loginTitle: String
    let emailLabel: String
    let codeLabel: String
    let disclaimer: String
    let postLogin: [String]

    static let en = WebAnchors(loginTitle: "Sign in to Myra", emailLabel: "Email address",
                               codeLabel: "6-digit code", disclaimer: "A note about",
                               postLogin: ["A note about", "help you", "privacy-friendly", "Good "])
    static let de = WebAnchors(loginTitle: "Myra AI Workspace anmelden", emailLabel: "E-Mail-Adresse",
                               codeLabel: "6-stelliger Code", disclaimer: "Hinweis zu",
                               postLogin: ["Hinweis zu", "kann ich", "Guten "])
}

extension XCTestCase {

    /// Extra values the Codemagic workflow writes into the creds sidecars (base_url, a11y_gate).
    /// Checked in both sidecar files so every suite sees the same configuration.
    func sidecarValue(_ key: String) -> String? {
        for path in ["/tmp/myra_screenshot_creds.json", "/tmp/myra_test_creds.json"] {
            if let data = FileManager.default.contents(atPath: path),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let v = obj[key], !v.isEmpty { return v }
        }
        return nil
    }

    /// The standard launch-argument set: push prompt suppressed, forced locale, and — when the
    /// sidecar carries base_url — the -MyraBaseURL override so the app targets INT (fixes land
    /// there pre-prod; the audit gate is only meaningful against an environment we control).
    /// `authViaCiSession: true` appends the CI-session launch args (AGF-1948) so the app boots
    /// ALREADY AUTHENTICATED — for tests that just need to REACH the authed app (keyboard capture,
    /// post-login /easy audit). It is OPT-IN, NOT the default: LoginTests' subject IS the login UI,
    /// so it must launch WITHOUT the cookie and drive the real form.
    func standardLaunchArgs(languages: String = "(en)", locale: String = "en_US",
                            authViaCiSession: Bool = false) -> [String] {
        var args = ["-MyraUITestSuppressPushPrompt", "-AppleLanguages", languages, "-AppleLocale", locale]
        if let base = sidecarValue("base_url") { args += ["-MyraBaseURL", base] }
        if authViaCiSession { args += ciSessionArgs() }
        return args
    }

    /// AGF-1948: when the workflow curled the CI session grant and wrote session_cookie + admin_host
    /// into the sidecar, these launch args make WebView.swift inject the aig_admin cookie before the
    /// first load → the app boots authenticated (no login-UI drive, no login flake). Empty when the
    /// sidecar lacks them (then ensureLoggedIn falls back to the real login round-trip).
    func ciSessionArgs() -> [String] {
        guard let token = sidecarValue("session_cookie"), let host = sidecarValue("admin_host") else { return [] }
        return ["-MyraCISessionCookie", token, "-MyraAdminHost", host]
    }

    /// Apple's accessibility audit over the current screen (labels, contrast, hit regions — incl.
    /// the WKWebView's web content). `gate: false` = log-only baseline (grep A11YAUDIT);
    /// `gate: true` = any issue fails the test.
    func runA11yAudit(_ app: XCUIApplication, label: String, gate: Bool) throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("performAccessibilityAudit needs iOS 17+") }
        var count = 0
        try app.performAccessibilityAudit { issue in
            count += 1
            NSLog("A11YAUDIT[\(label)] #\(count): type=\(issue.auditType.rawValue) — \(issue.compactDescription)")
            return !gate // true = ignore (log-only)
        }
        NSLog("A11YAUDIT[\(label)]: total \(count) issue(s), gate=\(gate)")
    }

    /// First element of ANY type whose label contains `text` (headings/static text/links survive
    /// the Xcode 26.4 exposure regression). CONTAINS[c]: WebKit exposes CSS `text-transform` in the
    /// accessibility label (AGF-1866 uppercased the app's buttons), so a case-sensitive match on a
    /// human-readable label silently found nothing — match case-insensitively.
    func anyLabeled(in webView: XCUIElement, _ text: String) -> XCUIElement {
        webView.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// Tap `dy` points below the CENTER of an exposed anchor element.
    func tapBelow(_ anchor: XCUIElement, dy: CGFloat) {
        anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: dy)).tap()
    }

    func settleWait(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [expectation(description: "settle")], timeout: seconds)
    }

    /// Focus the /easy composer textarea and raise the software keyboard, ROBUSTLY. Anchors on the
    /// composer's OWN exposed elements (the "Web search"/"Websuche" chip at the card top, or the
    /// "Privacy"/"Datenschutz" toolbar pill at the card bottom) rather than a blind offset from the
    /// distant greeting — a fixed greeting offset drifts with the greeting length + dark mode and
    /// (AGF-1948 keyboard-check) tapped the mic button, triggering DICTATION instead of the keyboard.
    /// Returns true once app.keyboards appears.
    @discardableResult
    func focusComposer(app: XCUIApplication, webView: XCUIElement) -> Bool {
        // The textarea sits just BELOW the top chip and ABOVE the toolbar pill. Tap ~55pt below the
        // chip's center (into the textarea), then, if needed, ~70pt ABOVE the toolbar pill.
        let topChip = ["Web search", "Websuche"].map { anyLabeled(in: webView, $0) }.first { $0.exists }
        if let chip = topChip { tapBelow(chip, dy: 55) }
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) { return true }

        let toolbarPill = ["Privacy", "Datenschutz", "Preview", "Vorschau"].map { anyLabeled(in: webView, $0) }.first { $0.exists }
        if let pill = toolbarPill { tapBelow(pill, dy: -70) }   // negative = above → the textarea
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) { return true }

        // Last resort: the greeting-anchored offset (the historical path).
        let greeting = ["morning", "afternoon", "evening", "help you", "Guten", "kann ich"]
            .map { anyLabeled(in: webView, $0) }.first { $0.exists }
        if let g = greeting { tapBelow(g, dy: 150) }
        return app.keyboards.firstMatch.waitForExistence(timeout: 6)
    }

    /// Full email-OTP login round-trip on the live login page. Returns false — after NSLogging the
    /// failing step (grep WEBFLOW) — so callers assert with their own message. The software-keyboard
    /// rise on the input taps is a functional requirement here (typeText needs focus), which makes
    /// every caller implicitly a virtual-keyboard check too.
    @discardableResult
    func loginRoundTrip(app: XCUIApplication, webView: XCUIElement,
                        email: String, otp: String, anchors: WebAnchors = .en) -> Bool {
        let title = anyLabeled(in: webView, anchors.loginTitle)
        guard title.waitForExistence(timeout: 40) else { NSLog("WEBFLOW: login title never appeared"); return false }
        settleWait(2)

        // Step 1: "CONTINUE WITH EMAIL CODE" sits ~59pt below the title's center; retry — a first
        // synthetic tap sometimes only grants the webview first-responder status.
        var emailLabel = anyLabeled(in: webView, anchors.emailLabel)
        for attempt in 1...3 where !emailLabel.exists {
            tapBelow(title, dy: 59)
            settleWait(2)
            emailLabel = anyLabeled(in: webView, anchors.emailLabel)
            NSLog("WEBFLOW: email-step reveal attempt \(attempt) -> \(emailLabel.exists)")
        }
        guard emailLabel.exists else { NSLog("WEBFLOW: email step never appeared"); return false }

        // Step 2: gesture-tap the input (~45pt below its label) so the keyboard rises, then type.
        tapBelow(emailLabel, dy: 45)
        guard app.keyboards.firstMatch.waitForExistence(timeout: 10) else {
            NSLog("WEBFLOW: software keyboard did not rise on the email input"); return false
        }
        app.typeText(email + "\n") // Return submits the single-input form ("Send code")
        settleWait(3)

        // Step 3: the 6-digit code input (label + "we sent a code" hint sit above it).
        let codeLabel = anyLabeled(in: webView, anchors.codeLabel)
        guard codeLabel.waitForExistence(timeout: 15) else { NSLog("WEBFLOW: code step never appeared"); return false }
        tapBelow(codeLabel, dy: 70)
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { tapBelow(codeLabel, dy: 45) }
        guard app.keyboards.firstMatch.waitForExistence(timeout: 5) else {
            NSLog("WEBFLOW: software keyboard did not rise on the code input"); return false
        }
        app.typeText(otp + "\n") // 6 digits enable the submit; Return signs in
        settleWait(6)
        return true
    }

    /// State-agnostic login: tests share the app's persistent websiteDataStore, so a prior test's
    /// session cookie may boot the app ALREADY authenticated (the keyboard capture failed exactly
    /// so after L-2 ran first). Detect the post-login state quickly; only run the round-trip when
    /// the login page is actually showing.
    @discardableResult
    func ensureLoggedIn(app: XCUIApplication, webView: XCUIElement,
                        email: String, otp: String, anchors: WebAnchors = .en) -> Bool {
        if postLoginSignal(in: webView, timeout: 8, anchors: anchors) { NSLog("WEBFLOW: already authenticated"); return true }
        if anyLabeled(in: webView, anchors.loginTitle).waitForExistence(timeout: 15) {
            return loginRoundTrip(app: app, webView: webView, email: email, otp: otp, anchors: anchors)
        }
        // Neither state resolved yet — one more generous post-login check (slow SPA boot).
        return postLoginSignal(in: webView, timeout: 20, anchors: anchors)
    }

    /// Post-login signal on the exposed-labels subset: the /easy greeting/subtitle or the first-run
    /// disclaimer. (The old "Open navigation menu" hamburger is a BUTTON — invisible under the
    /// Xcode 26.4 exposure regression.)
    func postLoginSignal(in webView: XCUIElement, timeout: TimeInterval = 30,
                         anchors: WebAnchors = .en) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let candidates = anchors.postLogin
        while Date() < deadline {
            for c in candidates where anyLabeled(in: webView, c).exists { return true }
            settleWait(1)
        }
        return false
    }

    /// Dismiss the first-run "A note about MYRA AI" disclaimer if present (GOT IT is a button —
    /// not exposed — tap its band anchored on the exposed note text).
    func dismissFirstRunDisclaimer(app: XCUIApplication, webView: XCUIElement,
                                   anchors: WebAnchors = .en) {
        let note = anyLabeled(in: webView, anchors.disclaimer)
        if note.waitForExistence(timeout: 8) {
            tapBelow(note, dy: 320)
            settleWait(2)
        }
    }
}
