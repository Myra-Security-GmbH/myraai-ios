import XCTest

/// AGF-6890: the one page-load budget of the UI guards.
enum PageLoad {
    /// FAILURE bound only for every wait for a `PAGE ...` line (launch or document replacement): a passing run waits for the observed
    /// line and returns the moment it appears, never for this ceiling. A cold, loaded simulator took ~38 s to show the
    /// page, so a guessed wall-clock figure below that turns machine speed into a red guard.
    static let failureCeiling: TimeInterval = 120
}

extension XCTestCase {
    /// Polls the probe page's log until it contains `text`. Shared by NavigationGuards, DownloadGuards and
    /// ConnectorAuthGuards (one implementation; each class only adds its own log/attachment prefix).
    func waitForNavlog(_ app: XCUIApplication, containing text: String, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { readNavlog(app).contains(text) }
    }

    /// AGF-6890: like `waitForNavlog(_:containing:)` for several alternatives; returns the log snapshot in which ANY of
    /// `texts` was first seen, or nil on timeout.
    func waitForNavlog(_ app: XCUIApplication, containingAny texts: [String], timeout: TimeInterval) -> String? {
        var seen: String?
        _ = waitUntil(timeout: timeout) {
            let log = readNavlog(app)
            if texts.contains(where: { log.contains($0) }) { seen = log; return true }
            return false
        }
        return seen
    }

    /// AGF-6890: the one poll loop of the UI guards (0.3 s period). Checks `cond` at least once, then until it holds or
    /// `timeout` elapsed. The navlog and line-count waits are built on it.
    func waitUntil(timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if cond() { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// The probe page's log, as exposed to accessibility (one or more static texts).
    func readNavlog(_ app: XCUIApplication) -> String {
        let texts = app.webViews.firstMatch.staticTexts
        return texts.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// AGF-6890: taps `element`, waits for the page's own acknowledgement line `ack`, and re-taps only while `ack` is
    /// still absent (a tap eaten by an animating overlay or a slow main thread). The probe pages log the ack
    /// synchronously in the click handler before any native call, so once `ack` is seen the request left exactly once
    /// and is never doubled. Every call logs `TAPACK <id> attempts=<n> ack=<seen|missing>`; a retry also attaches the
    /// screenshot `tapack_<id>_<n>`. Callers assert the result. `ack` must be unique to this tap (e.g. carry a counter).
    func tapAcknowledged(_ app: XCUIApplication, _ element: XCUIElement, ack: String,
                         attempts: Int = 3, perAttempt: TimeInterval = 5) -> Bool {
        let id = element.identifier
        var used = 0
        var seen = false
        while used < attempts && !seen {
            used += 1
            element.tap()
            seen = waitForNavlog(app, containing: ack, timeout: perAttempt)
            if used > 1 { attachScreenshot(prefix: "tapack", "\(id)_\(used)") }
        }
        logProbeLine(tag: "TAPACK", "\(id) attempts=\(used) ack=\(seen ? "seen" : "missing")")
        return seen
    }

    /// Keeps a screenshot as the attachment `<prefix>_<name>`.
    func attachScreenshot(prefix: String, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(prefix)_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One flat log line, tagged (e.g. "NAVGUARD"), to stdout and the system log.
    func logProbeLine(tag: String, _ line: String) {
        let flat = line.replacingOccurrences(of: "\n", with: " | ")
        print("\(tag) \(flat)")
        NSLog("%@ %@", tag, flat)
    }
}
