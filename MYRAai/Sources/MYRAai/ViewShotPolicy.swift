import Foundation

/// AGF-6807: the native feedback screenshot (`window.webkit.messageHandlers.captureViewport`) — the PURE part.
///
/// The SPA asks for the pixels of its own web view (`__myraNativeCaps.viewSnapshot === true`), because html2canvas
/// cannot draw what WKWebView composites natively. The controller (NativeBridge.swift, ViewShotController) does the
/// UIKit work; every decision that can be tested without a device lives here: the callback-name shape, the size caps
/// (the same integer maths as Android's ViewShot.kt), the reply shapes, the one-in-flight gate and the
/// replaced-document rule. Foundation-only, so the unit-test bundle compiles it.
enum ViewShotPolicy {
    /// Cross-platform contract with Android (ViewShot.kt) and the SPA.
    static let maxLongSidePx = 2560
    static let maxPixels = 8_000_000
    static let maxBytes = 10 * 1024 * 1024
    static let jpegQuality = 0.82
    /// A capture that has not produced a reply this long after the request is settled with render_error.
    static let watchdog: TimeInterval = 1.0
    /// After a capture settles, a new request within this window is refused (render_error).
    static let cooldown: TimeInterval = 0.5

    enum Reason: String {
        case unsupported                         // never emitted by iOS (the capability is advertised); wire parity only
        case renderError = "render_error"
        case secureView = "secure_view"
        case tooLarge = "too_large"
    }

    static let namePrefix = "__myraOnViewShot_"

    /// The callback name out of a message body (shared rule, see BridgeReply): `__myraOnViewShot_` + 1...16 ASCII digits.
    static func callbackName(from body: Any?) -> String? {
        BridgeReply.callbackName(from: body, prefix: namePrefix)
    }

    /// The pixel size of the delivered JPEG for a web view of `width` x `height` pixels: the long side capped at
    /// `maxLongSidePx`, the area at `maxPixels`, never upscaled, each side at least 1. nil for a non-positive input.
    static func scaledSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        var nw = width, nh = height
        let cap = maxLongSidePx
        if max(nw, nh) > cap {
            if nw >= nh {
                nh = max(1, Int(Int64(nh) * Int64(cap) / Int64(nw)))
                nw = cap
            } else {
                nw = max(1, Int(Int64(nw) * Int64(cap) / Int64(nh)))
                nh = cap
            }
        }
        if Int64(nw) * Int64(nh) > Int64(maxPixels) {
            let s = (Double(maxPixels) / (Double(nw) * Double(nh))).squareRoot()
            nw = max(1, Int(Double(nw) * s))
            nh = max(1, Int(Double(nh) * s))
            while Int64(nw) * Int64(nh) > Int64(maxPixels) {
                if nw >= nh { nw -= 1 } else { nh -= 1 }
            }
        }
        return (nw, nh)
    }

    /// The web view's size in whole device pixels, or nil when any input is NaN, infinite, or the result is below 1 in
    /// either dimension (so `Int(...)` never traps and a bad size settles as render_error). Sides beyond Int range
    /// are clamped to `Int32.max`, which `scaledSize` then caps.
    static func pixelSize(widthPoints: Double, heightPoints: Double, scale: Double) -> (width: Int, height: Int)? {
        let w = (widthPoints * scale).rounded()
        let h = (heightPoints * scale).rounded()
        guard w.isFinite, h.isFinite, w >= 1, h >= 1 else { return nil }
        let limit = Double(Int32.max)
        return (Int(min(w, limit)), Int(min(h, limit)))
    }

    static func failureReply(_ reason: Reason) -> [String: Any] {
        ["ok": false, "reason": reason.rawValue]
    }

    /// The success reply for the encoder's output, or a failure reply when the output is not what the page may
    /// receive: not a JPEG (SOI `FF D8 FF` ... EOI `FF D9`), dimensions outside the caps, or over `maxBytes`.
    static func successReply(jpeg: Data, width: Int, height: Int) -> [String: Any] {
        let n = jpeg.count
        guard n >= 5, width >= 1, height >= 1, max(width, height) <= maxLongSidePx,
              Int64(width) * Int64(height) <= Int64(maxPixels) else { return failureReply(.renderError) }
        let bytes = [UInt8](jpeg)
        guard bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF,
              bytes[n - 2] == 0xFF, bytes[n - 1] == 0xD9 else { return failureReply(.renderError) }
        guard n <= maxBytes else { return failureReply(.tooLarge) }
        return ["ok": true,
                "type": "image/jpeg",
                "data": jpeg.base64EncodedString(),
                "width": width,
                "height": height]
    }

    /// The JS that hands `reply` to the page's callback (shared builder, see BridgeReply).
    static func replyScript(callbackName name: String?, reply: [String: Any]) -> String? {
        BridgeReply.script(callbackName: name, prefix: namePrefix, argument: .object(reply))
    }

    /// One capture in flight, then a cooldown from its settle. Main thread only. The clock is injectable.
    final class Gate {
        enum Start: Equatable {
            case started(Int)
            case busy
            case cooling
        }

        private let clock: () -> TimeInterval
        private var nextToken = 0
        private var settledAt: TimeInterval?
        private(set) var inFlight: Int?

        init(clock: @escaping () -> TimeInterval) { self.clock = clock }

        func tryStart() -> Start {
            if inFlight != nil { return .busy }
            if let settledAt, clock() - settledAt < ViewShotPolicy.cooldown { return .cooling }
            nextToken += 1
            inFlight = nextToken
            return .started(nextToken)
        }

        /// True exactly once per token, and only while it is the one in flight; the cooldown starts here.
        func settle(_ token: Int) -> Bool {
            guard inFlight == token else { return false }
            inFlight = nil
            settledAt = clock()
            return true
        }
    }

    /// A reply is delivered only into the document that asked, and only while that document is an owned app page.
    static func shouldDeliver(requestDocument: Int, currentDocument: Int, currentURL: URL?) -> Bool {
        BridgeReply.shouldDeliver(requestDocument: requestDocument, currentDocument: currentDocument, currentURL: currentURL)
    }

    /// Appended inside `window.__myraNativeCaps = { ... }`.
    static let capsJS = ", viewSnapshot: true"
}
