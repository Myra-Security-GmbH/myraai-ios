import XCTest

extension XCTestCase {
    /// The system share sheet (UIActivityViewController) — matched by the identifiers / labels it exposes. The probe
    /// pages have no "Copy" / "Close" control of their own, so those labels can only come from the sheet.
    /// Shared by NavigationGuards (share bridge) and DownloadGuards (file downloads).
    func waitForShareSheet(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let candidates = [app.otherElements["ActivityListView"], app.navigationBars["UIActivityContentView"],
                          app.buttons["Copy"], app.cells["Copy"], app.buttons["Close"]]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if candidates.contains(where: { $0.exists }) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return candidates.contains(where: { $0.exists })
    }
}
