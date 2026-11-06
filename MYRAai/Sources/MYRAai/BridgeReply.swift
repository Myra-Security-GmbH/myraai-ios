import Foundation

/// AGF-6849: the ONE way the shell answers a page that asked through a callback-pull handler (the contract Android
/// ships as AGF-6813 and the screenshot bridge ships as AGF-6807): the page posts a callback NAME, the shell calls
/// `window[name](reply)` in the document that asked, and nowhere else. Foundation-only, so the logic-test bundle
/// compiles it; ViewShotPolicy and DeviceTokenPolicy delegate here.
enum BridgeReply {

    /// What the page's callback receives.
    enum Argument {
        case object([String: Any])
        case string(String)
        case null
    }

    /// The callback name out of a message body: a String of exactly `prefix` + 1...16 ASCII digits.
    /// Byte-wise on purpose (not a regex): `$` would accept a trailing newline, `\d` Unicode digits.
    static func callbackName(from body: Any?, prefix: String) -> String? {
        guard let name = body as? String else { return nil }
        let head = Array(prefix.utf8)
        let bytes = Array(name.utf8)
        guard bytes.count > head.count, bytes.count <= head.count + 16, bytes.starts(with: head) else { return nil }
        for b in bytes[head.count...] where b < 0x30 || b > 0x39 { return nil }
        return name
    }

    /// The JS that hands `argument` to the page's callback: a guarded call with a JSON argument. nil unless the name
    /// passes `callbackName` again (a second check at the one place a name becomes code) or the argument cannot be
    /// encoded (a NaN in an object would raise an uncatchable Objective-C exception, so it is checked first).
    static func script(callbackName name: String?, prefix: String, argument: Argument) -> String? {
        guard let name, callbackName(from: name, prefix: prefix) == name else { return nil }
        var json: String
        switch argument {
        case .null:
            json = "null"
        case .string(let s):
            guard let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            json = text
        case .object(let o):
            guard JSONSerialization.isValidJSONObject(o),
                  let data = try? JSONSerialization.data(withJSONObject: o),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            json = text
        }
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                   .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "typeof \(name) === \"function\" && \(name)(\(json));"
    }

    /// A reply is delivered only into the document that asked, and only while that document is an owned app page.
    static func shouldDeliver(requestDocument: Int, currentDocument: Int, currentURL: URL?) -> Bool {
        requestDocument == currentDocument && NavigationPolicy.isOwnedSPAPage(currentURL)
    }
}

/// Counts the documents the web view has committed; a request remembers the count it was made in, a reply is
/// delivered only while the count is unchanged. One per NativeBridge (`bridge.page`), shared by every callback-pull
/// controller so two of them can never disagree about which document is current.
@MainActor
final class PageIdentity {
    private(set) var generation = 0

    /// A new document was committed in the web view (also after a WebContent process reload).
    func documentCommitted() {
        generation += 1
    }
}

/// AGF-6849: the APNs device token (`window.webkit.messageHandlers.getDeviceToken`) — the PURE part. Request/reply, as
/// on Android: the page asks with `__myraOnPushToken_<n>`, only the app's own current page is answered, the token is
/// never pushed into a page that did not ask.
enum DeviceTokenPolicy {
    static let prefix = "__myraOnPushToken_"
    /// Requests parked while the token is not known yet (current document only).
    static let maxParked = 8

    enum TokenState: Equatable {
        case pending
        case available(String)
        case failed
    }

    enum Action: Equatable {
        case reply(String?)   // answer now: the token, or null
        case park             // the token is not known yet
    }

    static func callbackName(from body: Any?) -> String? {
        BridgeReply.callbackName(from: body, prefix: prefix)
    }

    /// An APNs token as the shell hands it out: 1...200 lowercase hex characters (the real one is 64).
    static func isValidToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard !bytes.isEmpty, bytes.count <= 200 else { return false }
        return bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// What a request gets in the given state. An unusable token is answered null, never passed on.
    static func decide(_ state: TokenState) -> Action {
        switch state {
        case .pending: return .park
        case .failed: return .reply(nil)
        case .available(let t): return .reply(isValidToken(t) ? t : nil)
        }
    }

    static func replyScript(callbackName name: String?, token: String?) -> String? {
        BridgeReply.script(callbackName: name, prefix: prefix, argument: token.map { .string($0) } ?? .null)
    }

    /// Requests waiting for the token. Main thread only.
    struct Pending {
        enum Park: Equatable {
            case parked
            case full
        }

        private(set) var entries: [(name: String, document: Int)] = []

        var count: Int { entries.count }

        /// Parks a request made in `document`. Entries of any other document than `currentDocument` are evicted first
        /// (that document is gone, nobody is waiting); at most `maxParked` stay, the next one is `.full` (answered null).
        mutating func park(name: String, document: Int, currentDocument: Int) -> Park {
            entries.removeAll { $0.document != currentDocument }
            guard document == currentDocument, entries.count < maxParked else { return .full }
            entries.append((name, document))
            return .parked
        }

        /// Everything parked, in arrival order; the queue is empty afterwards.
        mutating func drain() -> [(name: String, document: Int)] {
            defer { entries = [] }
            return entries
        }
    }
}
