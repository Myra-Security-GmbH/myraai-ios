import Foundation

/// AGF-6807: the native feedback screenshot (`window.webkit.messageHandlers.captureViewport`) — the PURE part.
/// STUB (red-first): real signatures, failing values.
enum ViewShotPolicy {
    static let maxLongSidePx = 2560
    static let maxPixels = 8_000_000
    static let maxBytes = 10 * 1024 * 1024
    static let jpegQuality = 0.82
    static let watchdog: TimeInterval = 1.0
    static let cooldown: TimeInterval = 0.5

    enum Reason: String {
        case unsupported
        case renderError = "render_error"
        case secureView = "secure_view"
        case tooLarge = "too_large"
    }

    static func callbackName(from body: Any?) -> String? { nil }

    static func scaledSize(width: Int, height: Int) -> (width: Int, height: Int)? { nil }

    static func failureReply(_ reason: Reason) -> [String: Any] { [:] }

    static func successReply(jpeg: Data, width: Int, height: Int) -> [String: Any] { failureReply(.renderError) }

    static func replyScript(callbackName: String?, reply: [String: Any]) -> String? { nil }

    final class Gate {
        enum Start: Equatable {
            case started(Int)
            case busy
            case cooling
        }

        init(clock: @escaping () -> TimeInterval) {}
        func tryStart() -> Start { .busy }
        func settle(_ token: Int) -> Bool { false }
        var inFlight: Int? { nil }
    }

    static func shouldDeliver(requestDocument: Int, currentDocument: Int, currentURL: URL?) -> Bool { false }

    static let capsJS = ""
}
