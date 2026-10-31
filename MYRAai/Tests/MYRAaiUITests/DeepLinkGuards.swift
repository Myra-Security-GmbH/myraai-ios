import XCTest

/// AGF-5758 — a tapped `https://ai.myra.eu/shared/<id>` link must open IN the app, on that page.
///
/// Reporter (prod feedback 71f609f8, 1.0.14): the shared link never reached the web view. The shell's routing code is
/// unit-tested (DeepLinkGateTests) but nothing exercised the real delivery: system -> associated domain -> app ->
/// `.onContinueUserActivity` -> `openDeepLink` -> web view. These guards do, on the simulator, through
/// `XCUIDevice.shared.system.open(url)` (the SYSTEM path, not the DEBUG `-MyraUITestUserActivityURL` hook).
///
/// The simulator only routes `https://ai.myra.eu` to the app when the build carries the associated-domain
/// entitlement; the `deeplink-guard` workflow builds the app with `Config/DeepLinkGuard.xcconfig`
/// (`MYRAai.debug-sim.entitlements`, `applinks:ai.myra.eu?mode=developer`).
///
/// Three outcomes, told apart by the failure message:
///   - `HARNESS: routing not established`  — the app did not come to the foreground or Safari took the link: the
///     harness (entitlement / swcd / AASA / prod drift) is broken, NOT the product. Nothing else is concluded.
///   - `PRODUCT-ENV: share API not 404`    — the app loaded the page but the share API did not answer "not found".
///   - `PRODUCT: link not loaded`          — routing worked and the page did not load.
///
/// The probe page is the public "Not found" page of an all-zero share id: no login, no secrets.
final class DeepLinkGuards: XCTestCase {

    private let link = URL(string: "https://ai.myra.eu/shared/" + String(repeating: "0", count: 64))!
    private let notFound = ["Not found", "Nicht gefunden"]                      // misc.shared.notFoundTitle (en/de)
    private let loadError = ["This shared conversation could not be loaded",   // misc.shared.loadErrorTitle (en/de)
                             "Diese geteilte Konversation konnte nicht geladen werden"]

    /// A FRESH proxy per query (see NavigationGuards.safari).
    private var safari: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.mobilesafari") }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        safari.terminate()
        // A notification-permission alert (the system launch carries no -MyraUITestSuppressPushPrompt) must not hide
        // the page. No interruption monitor: the test never interacts with the app, so a monitor would never fire;
        // dismissNotificationAlert() polls the springboard instead.
    }

    override func tearDown() {
        XCUIApplication().terminate()
        super.tearDown()
    }

    // MARK: - Guards

    /// App running and loaded, sent to the background, then the link is opened by the system.
    func test_warm() throws {
        let app = launchApp()
        XCUIDevice.shared.press(.home)
        let backgrounded = expectation(for: NSPredicate(format: "state IN %@", [XCUIApplication.State.runningBackground.rawValue,
                                                                                  XCUIApplication.State.runningBackgroundSuspended.rawValue]),
                                       evaluatedWith: app)
        XCTAssertTrue(XCTWaiter().wait(for: [backgrounded], timeout: 10) == .completed,
                      "HARNESS: routing not established — the app did not go to the background (state \(app.state.rawValue))")
        openBySystem()
    }

    /// App not running, the link is opened by the system. Independent of test order: right after install swcd may not
    /// have finished the `?mode=developer` AASA fetch (the first system.open then goes to Safari), so routing is
    /// primed first and only then is the real cold open done.
    func test_cold() throws {
        let app = launchApp()
        primeRouting()   // leaves the app running in the foreground
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "HARNESS: routing not established — the app did not terminate")
        openBySystem()
    }

    // MARK: - Steps

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += standardLaunchArgs()   // never -MyraUITestUserActivityURL: this is the system path
        app.launch()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30), "the first page never loaded (no web view)")
        XCTAssertTrue(waitForGone(app.descendants(matching: .any)["myra-privacy-shield"], timeout: 10), "privacy shield still up after launch")
        return app
    }

    /// Opens the link by the system and reports whether the system routed it to OUR app (foreground) and not Safari.
    /// A FRESH proxy: a terminated proxy (test_cold) never reports the relaunch (NavigationGuards.swift).
    private func openAndCheckRouted(timeout: TimeInterval) -> (app: XCUIApplication, routed: Bool, why: String) {
        XCUIDevice.shared.system.open(link)
        let app = XCUIApplication()
        guard app.wait(for: .runningForeground, timeout: timeout) else {
            return (app, false, "the app is not in the foreground after system.open (state \(app.state.rawValue))")
        }
        if safari.state == .runningForeground { return (app, false, "Safari took the link") }
        return (app, true, "")
    }

    /// Waits (up to ~60 s) until the system routes the link to the app. The attempt only checks routing, it asserts
    /// no page. Safari is terminated after a miss so the next attempt starts clean.
    private func primeRouting() {
        let deadline = Date().addingTimeInterval(60)
        var why = ""
        repeat {
            XCUIDevice.shared.press(.home)
            let attempt = openAndCheckRouted(timeout: 8)
            if attempt.routed { return }
            why = attempt.why
            safari.terminate()
            RunLoop.current.run(until: Date().addingTimeInterval(5))
        } while Date() < deadline
        XCTFail("HARNESS: routing not established (AASA not yet associated) — \(why)")
    }

    private func openBySystem() {
        // Positive control: the system must have routed the link to OUR app, not to Safari.
        let opened = openAndCheckRouted(timeout: 10)
        let app = opened.app
        XCTAssertTrue(opened.routed, "HARNESS: routing not established — \(opened.why)")
        attachScreenshot(app, name: "after-open")

        // Product assert: the shared page's "Not found" heading is exposed and visible within 20 s.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            dismissNotificationAlert()
            if anyHittable(app, loadError) {
                XCTFail("PRODUCT-ENV: share API not 404 — the shared page rendered its load-error state, not \"Not found\"")
                return
            }
            if anyHittable(app, notFound), !app.descendants(matching: .any)["myra-privacy-shield"].exists { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        attachScreenshot(app, name: "product-red")
        XCTFail("PRODUCT: link not loaded — no \"Not found\" heading within 20 s of a routed universal link")
    }

    // MARK: - Helpers

    private func anyHittable(_ app: XCUIApplication, _ labels: [String]) -> Bool {
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        return match.exists && match.isHittable
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Dismiss a permission alert by tapping it on the springboard (polled by the wait loops).
    private func dismissNotificationAlert() {
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return }
        for label in ["Don\u{2019}t Allow", "Don't Allow", "Nicht erlauben"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
