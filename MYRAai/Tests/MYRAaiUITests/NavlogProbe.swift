import XCTest

extension XCTestCase {
    /// Polls the probe page's log until it contains `text`. Shared by NavigationGuards, DownloadGuards and
    /// ConnectorAuthGuards (one implementation; each class only adds its own log/attachment prefix).
    func waitForNavlog(_ app: XCUIApplication, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readNavlog(app).contains(text) { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// The probe page's log, as exposed to accessibility (one or more static texts).
    func readNavlog(_ app: XCUIApplication) -> String {
        let texts = app.webViews.firstMatch.staticTexts
        return texts.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty }.joined(separator: "\n")
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
