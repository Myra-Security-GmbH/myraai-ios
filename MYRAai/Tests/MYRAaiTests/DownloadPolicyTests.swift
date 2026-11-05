import XCTest

/// AGF-3621 — unit matrix of DownloadPolicy (the source file is compiled into this logic-test bundle; Foundation
/// only, no app host). The on-device proof is DownloadGuards (UI tests).
final class DownloadPolicyTests: XCTestCase {

    // MARK: shouldDownload (navigation action)

    func test_shouldDownload_matrix() {
        typealias D = DownloadPolicy.DownloadActionDecision
        let rows: [(String, Bool, Bool, D)] = [
            ("blob", true, true, .download),
            ("BLOB", true, true, .download),
            ("data", true, true, .download),
            ("https", true, true, .cancelWithAlert),
            ("http", true, true, .cancelWithAlert),
            ("file", true, true, .cancelWithAlert),
            ("javascript", true, true, .cancelWithAlert),
            ("", true, true, .cancelWithAlert),
            ("blob", false, true, .cancelSilently),
            ("blob", true, false, .cancelSilently),
            ("blob", false, false, .cancelSilently),
            ("https", false, true, .cancelSilently),
            ("https", true, false, .cancelSilently),
        ]
        for (scheme, app, main, want) in rows {
            XCTAssertEqual(DownloadPolicy.shouldDownload(scheme: scheme, sourceIsAppPage: app, targetIsMainFrame: main), want,
                           "scheme=\(scheme) app=\(app) main=\(main)")
        }
    }

    // MARK: shouldDownloadResponse

    func test_shouldDownloadResponse_matrix() {
        let rows: [(Bool, String, String, Bool, Bool)] = [
            (true, "https", "ai.myra.eu", true, true),
            (true, "HTTPS", "ai.myra.eu", true, true),
            (true, "https", "ai.myra.eu", false, false),
            (false, "https", "ai.myra.eu", true, false),
            (true, "http", "ai.myra.eu", true, false),
            (true, "blob", "ai.myra.eu", true, false),
            (true, "https", "evil.example", true, false),
            (true, "https", "ai.myra.eu.evil.example", true, false),
            (true, "https", "", true, false),
        ]
        for (main, scheme, host, att, want) in rows {
            XCTAssertEqual(DownloadPolicy.shouldDownloadResponse(isMainFrame: main, scheme: scheme, host: host, isAttachment: att), want,
                           "main=\(main) scheme=\(scheme) host=\(host) attachment=\(att)")
        }
    }

    // MARK: isAttachment

    func test_isAttachment_matrix() {
        XCTAssertTrue(DownloadPolicy.isAttachment(contentDisposition: "attachment"))
        XCTAssertTrue(DownloadPolicy.isAttachment(contentDisposition: "Attachment; filename=\"x\""))
        XCTAssertTrue(DownloadPolicy.isAttachment(contentDisposition: " attachment ;"))
        XCTAssertFalse(DownloadPolicy.isAttachment(contentDisposition: "inline"))
        XCTAssertFalse(DownloadPolicy.isAttachment(contentDisposition: "attachmentx"))
        XCTAssertFalse(DownloadPolicy.isAttachment(contentDisposition: ""))
        XCTAssertFalse(DownloadPolicy.isAttachment(contentDisposition: nil))
    }

    // MARK: isAcceptableSize

    func test_isAcceptableSize_matrix() {
        XCTAssertTrue(DownloadPolicy.isAcceptableSize(expected: 0))
        XCTAssertTrue(DownloadPolicy.isAcceptableSize(expected: 1))
        XCTAssertTrue(DownloadPolicy.isAcceptableSize(expected: DownloadPolicy.maxBytes))
        XCTAssertFalse(DownloadPolicy.isAcceptableSize(expected: DownloadPolicy.maxBytes + 1))
        XCTAssertFalse(DownloadPolicy.isAcceptableSize(expected: -1))
        XCTAssertFalse(DownloadPolicy.isAcceptableSize(expected: Int64.min))
        XCTAssertEqual(DownloadPolicy.maxBytes, 104_857_600)
    }

    // MARK: validateFilename

    func test_validateFilename_accepts_and_returns_unchanged() {
        let nfd = "Bericht_U\u{0308}bersicht (1).pdf"
        let nfc = "Bericht_\u{00DC}bersicht (1).pdf"
        let accepted = ["Rechnung 50%.pdf", "Q&A \u{2013} final.docx", "Umsatz (\u{20AC}).xlsx", "Angebot \u{00A7}3.pdf",
                        "Frage?.txt", "a:b.md", ".env", "a\u{200D}b", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}.txt",
                        "a\u{E000}b", nfc, nfd, "\u{1F600}.txt", String(repeating: "a", count: 255)]
        for name in accepted {
            XCTAssertEqual(DownloadPolicy.validateFilename(name), name, "should accept \(name.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    func test_validateFilename_rejects() {
        let rejected = ["", " ", ".", "..", "../x", "a/b", "a\\b", "a\"b", "a;b", "a\u{0}b", "a\nb", "a\u{7F}b", "a\u{85}b",
                        "x\u{202E}fdp.exe", "a\u{2066}b", "a\u{200B}b", "a\u{FEFF}b", "a\u{061C}b", "a\u{2028}b",
                        " lead", "trail ", String(repeating: "a", count: 256),
                        String(repeating: "a\u{0308}", count: 128)]
        // The last row is 128 x (a + U+0308): NFC = 128 x U+00E4 = 256 bytes -> rejected although the raw form is 384.
        for name in rejected {
            XCTAssertNil(DownloadPolicy.validateFilename(name), "should reject \(name.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    // MARK: destination

    func test_destination_containment() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("myra-save-test", isDirectory: true)
        let ok = DownloadPolicy.destination(in: dir, filename: "Bericht.txt")
        XCTAssertEqual(ok?.lastPathComponent, "Bericht.txt")
        XCTAssertNil(DownloadPolicy.destination(in: dir, filename: ".."))
        XCTAssertNil(DownloadPolicy.destination(in: dir, filename: "a/../../b"))
    }
}
