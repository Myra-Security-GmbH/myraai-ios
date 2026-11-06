import Foundation

/// AGF-3621 — the pure policy of the app's native file downloads (WKDownload → share sheet).
///
/// Foundation ONLY: this file is compiled into the MYRAaiTests logic bundle without the app, so the whole matrix is
/// unit-tested (MYRAaiTests/DownloadPolicyTests). The web view's page saves a file by clicking
/// `<a download=name href=blob:…>`; WebKit raises a navigation action with `shouldPerformDownload == true`, and the
/// app answers `.download` ONLY for the cases below — every other download action is cancelled, never navigated.
enum DownloadPolicy {

    enum DownloadActionDecision: Equatable {
        case download          // hand it to WKDownload
        case cancelSilently    // not the user's request (a preview / subframe / foreign page): log only
        case cancelWithAlert   // the app page asked, but we will not do it: tell the user
    }

    /// Mirrors the backend write/upload cap `MAX_CHAT_UPLOAD_BYTES` (src/admin/chat_files.tl). Cross-language
    /// constant: change both together.
    static let maxBytes: Int64 = 100 * 1024 * 1024

    /// A download action. `blob:` / `data:` links from the app page into the main frame are downloaded; a download
    /// from anywhere else (sandboxed preview, subframe, non-app page) is cancelled silently; any other scheme from
    /// the app page is cancelled with the alert (no silent dead button).
    static func shouldDownload(scheme: String, sourceIsAppPage: Bool, targetIsMainFrame: Bool) -> DownloadActionDecision {
        guard sourceIsAppPage, targetIsMainFrame else { return .cancelSilently }
        switch scheme.lowercased() {
        case "blob", "data": return .download
        default: return .cancelWithAlert
        }
    }

    /// A main-frame navigation RESPONSE that is an attachment from an https host we own (the generated-video
    /// Download link: cross-origin, so WebKit ignores the `download` attribute and the server answers with
    /// `Content-Disposition: attachment`). Everything else keeps today's behaviour (the caller allows it).
    static func shouldDownloadResponse(isMainFrame: Bool, scheme: String, host: String, isAttachment: Bool) -> Bool {
        isMainFrame && isAttachment && scheme.lowercased() == "https" && NavigationPolicy.isOwned(host)
    }

    /// True when the first token of a `Content-Disposition` header value, trimmed, is `attachment`
    /// (case-insensitive). nil / empty / `inline` / `attachmentx` are not.
    static func isAttachment(contentDisposition: String?) -> Bool {
        guard let value = contentDisposition else { return false }
        let first = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
    }

    /// 0 ... maxBytes. UNKNOWN (-1, NSURLResponseUnknownLength) is rejected: unknown is not ok.
    static func isAcceptableSize(expected: Int64) -> Bool {
        expected >= 0 && expected <= maxBytes
    }

    // Format controls rejected by name (bidi spoofing / invisible). ZWJ / ZWNJ (U+200C / U+200D) stay allowed
    // (emoji sequences, Persian).
    private static func isRejectedFormatControl(_ v: UInt32) -> Bool {
        switch v {
        case 0x061C, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    /// The filename is acceptable → returned UNCHANGED; otherwise nil (never rewritten). The complement of the
    /// server's stored-name rule (src/utils/safe_filename.tl `stored`), so every name the server can store is
    /// accepted — change both together. Deviations: the server never stores `"` or `;`, so a page asking for
    /// them is not a server-stored name and is rejected; bidi / invisible format controls are rejected. Rejected: empty, `.`, `..`, leading / trailing Unicode whitespace, `/` `\` `"` or `;`, C0 / C1 controls
    /// and DEL, the format controls above, more than 255 UTF-8 bytes (measured on the NFC form). Checked per
    /// unicode scalar, not per Character.
    static func validateFilename(_ name: String) -> String? {
        if name.isEmpty || name == "." || name == ".." { return nil }
        let scalars = Array(name.unicodeScalars)
        if let first = scalars.first, first.properties.isWhitespace { return nil }
        if let last = scalars.last, last.properties.isWhitespace { return nil }
        for s in scalars {
            let v = s.value
            if v == 0x2F || v == 0x5C || v == 0x22 || v == 0x3B { return nil }   // / \ " ;
            if v < 0x20 || (v >= 0x7F && v <= 0x9F) { return nil }   // C0, DEL, C1
            if isRejectedFormatControl(v) { return nil }
        }
        if name.precomposedStringWithCanonicalMapping.utf8.count > 255 { return nil }
        return name
    }

    /// `dir/filename` with a containment check (defence in depth behind `validateFilename`): nil when the
    /// candidate's parent is not exactly `dir`.
    static func destination(in dir: URL, filename: String) -> URL? {
        let candidate = dir.appendingPathComponent(filename, isDirectory: false)
        let parent = candidate.standardizedFileURL.deletingLastPathComponent().standardizedFileURL
        guard parent.path == dir.standardizedFileURL.path else { return nil }
        return candidate
    }
}
