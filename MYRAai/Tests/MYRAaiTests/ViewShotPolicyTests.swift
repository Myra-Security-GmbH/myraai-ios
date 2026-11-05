import XCTest

/// AGF-6807 — unit matrix of ViewShotPolicy (the source file is compiled into this logic-test bundle; no app host,
/// no simulator UI). Mirrors the Android ViewShotTest. The on-device proof is ViewShotGuards (UI tests).
final class ViewShotPolicyTests: XCTestCase {

    typealias P = ViewShotPolicy

    // MARK: - callback name

    func test_callback_name_accepts_one_to_sixteen_digits() {
        XCTAssertEqual(P.callbackName(from: "__myraOnViewShot_0"), "__myraOnViewShot_0")
        XCTAssertEqual(P.callbackName(from: "__myraOnViewShot_1234567890123456"), "__myraOnViewShot_1234567890123456")
        XCTAssertEqual(P.callbackName(from: "__myraOnViewShot_42"), "__myraOnViewShot_42")
    }

    func test_callback_name_rejects_everything_else() {
        let bad: [String] = [
            "", "__myraOnViewShot_", "__myraOnViewShot_12345678901234567",     // empty suffix, 17 digits
            "__myraOnViewShot_1\n", "__myraOnViewShot_1\r\n", "__myraOnViewShot_1 ", " __myraOnViewShot_1",
            "\n__myraOnViewShot_1", "__myraOnViewShot_1\u{0}", "__myraOnViewShot_1;alert(1)",
            "__myraOnViewShot_1(0)", "__myraOnViewShot_-1", "__myraOnViewShot_1.5", "__myraOnViewShot_0x1",
            "__myraOnViewShot_\u{FF11}",                 // fullwidth digit one
            "__myraOnViewShot_\u{0661}",                 // Arabic-Indic digit one
            "__myraOnViewShot_1\u{0661}",
            "__myraonviewshot_1", "__MYRAONVIEWSHOT_1", "myraOnViewShot_1", "__myraOnViewShot1",
            "__myraOnPushToken_1", "__myraOnViewShot_1__myraOnViewShot_2", "window.__myraOnViewShot_1",
        ]
        for name in bad {
            XCTAssertNil(P.callbackName(from: name), "accepted \(name.debugDescription)")
        }
    }

    func test_callback_name_rejects_non_string_bodies() {
        XCTAssertNil(P.callbackName(from: nil))
        XCTAssertNil(P.callbackName(from: 42))
        XCTAssertNil(P.callbackName(from: 1.5))
        XCTAssertNil(P.callbackName(from: true))
        XCTAssertNil(P.callbackName(from: NSNull()))
        XCTAssertNil(P.callbackName(from: ["name": "__myraOnViewShot_1"] as [String: Any]))
        XCTAssertNil(P.callbackName(from: ["__myraOnViewShot_1"]))
        XCTAssertNil(P.callbackName(from: Data("__myraOnViewShot_1".utf8)))
        XCTAssertNil(P.callbackName(from: NSNumber(value: 1)))
    }

    // MARK: - scaledSize

    private func assertWithinCaps(_ s: (width: Int, height: Int)?, file: StaticString = #filePath, line: UInt = #line) {
        guard let s else { return XCTFail("nil size", file: file, line: line) }
        XCTAssertGreaterThanOrEqual(s.width, 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(s.height, 1, file: file, line: line)
        XCTAssertLessThanOrEqual(max(s.width, s.height), P.maxLongSidePx, file: file, line: line)
        XCTAssertLessThanOrEqual(s.width * s.height, P.maxPixels, file: file, line: line)
    }

    private func assertSize(_ w: Int, _ h: Int, _ ew: Int, _ eh: Int, file: StaticString = #filePath, line: UInt = #line) {
        let s = P.scaledSize(width: w, height: h)
        XCTAssertEqual(s?.width, ew, "\(w)x\(h) width", file: file, line: line)
        XCTAssertEqual(s?.height, eh, "\(w)x\(h) height", file: file, line: line)
    }

    func test_full_resolution_device_frame_is_scaled_into_the_caps() {
        // The comment-3 addendum frame (a 1440x3120 device screen), same input/output as the Android ViewShotTest.
        assertSize(1440, 3120, 1181, 2560)
        assertWithinCaps(P.scaledSize(width: 1440, height: 3120))
    }

    func test_iphone_and_ipad_frames() {
        assertSize(1290, 2796, 1181, 2560)       // iPhone 15 Pro Max pixels
        assertSize(2064, 2752, 1920, 2560)       // iPad 13"
        assertSize(1179, 2556, 1179, 2556)       // iPhone 15 Pro: already within the caps
    }

    func test_landscape_and_long_side_bound() {
        assertSize(3120, 1440, 2560, 1181)
        assertSize(2560, 3200, 2048, 2560)
        assertSize(2561, 1, 2560, 1)
    }

    func test_small_frames_are_not_upscaled() {
        assertSize(1080, 2400, 1080, 2400)
        assertSize(1, 1, 1, 1)
        assertSize(2560, 2560, 2560, 2560)
    }

    func test_extreme_aspect_keeps_each_side_at_least_one() {
        assertSize(1, 100_000, 1, 2560)
        assertSize(100_000, 1, 2560, 1)
    }

    func test_non_positive_input_is_nil() {
        XCTAssertNil(P.scaledSize(width: 0, height: 100))
        XCTAssertNil(P.scaledSize(width: 100, height: 0))
        XCTAssertNil(P.scaledSize(width: -1, height: 100))
        XCTAssertNil(P.scaledSize(width: 100, height: -5))
        XCTAssertNil(P.scaledSize(width: 0, height: 0))
    }

    func test_every_size_in_a_sweep_is_within_the_caps_and_never_upscaled() {
        let sides = [1, 2, 3, 7, 100, 640, 1023, 1024, 1179, 1290, 1440, 2048, 2559, 2560, 2561, 2796, 3120, 4096, 9999, 100_000]
        for w in sides {
            for h in sides {
                let s = P.scaledSize(width: w, height: h)
                assertWithinCaps(s)
                if let s {
                    XCTAssertLessThanOrEqual(s.width, w, "\(w)x\(h) upscaled")
                    XCTAssertLessThanOrEqual(s.height, h, "\(w)x\(h) upscaled")
                }
            }
        }
    }

    // MARK: - replies

    /// A complete (tiny, structurally valid) JPEG: FF D8 FF ... FF D9.
    private func jpeg(_ size: Int = 10) -> Data {
        var b = [UInt8](repeating: 0x11, count: size)
        b[0] = 0xFF; b[1] = 0xD8; b[2] = 0xFF
        b[size - 2] = 0xFF; b[size - 1] = 0xD9
        return Data(b)
    }

    func test_failure_reply_shape_per_reason() {
        for (r, wire) in [(P.Reason.unsupported, "unsupported"), (.renderError, "render_error"),
                          (.secureView, "secure_view"), (.tooLarge, "too_large")] {
            let reply = P.failureReply(r)
            XCTAssertEqual(reply.count, 2, wire)
            XCTAssertEqual(reply["ok"] as? Bool, false, wire)
            XCTAssertEqual(reply["reason"] as? String, wire)
        }
    }

    func test_success_reply_for_a_valid_jpeg() {
        let data = jpeg(1000)
        let reply = P.successReply(jpeg: data, width: 1181, height: 2560)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["type"] as? String, "image/jpeg")
        XCTAssertEqual(reply["width"] as? Int, 1181)
        XCTAssertEqual(reply["height"] as? Int, 2560)
        XCTAssertEqual(reply.count, 5)
        let b64 = reply["data"] as? String ?? ""
        XCTAssertFalse(b64.isEmpty)
        XCTAssertFalse(b64.contains("\n") || b64.contains("\r"), "base64 has line breaks")
        XCTAssertEqual(Data(base64Encoded: b64), data, "base64 does not round-trip")
        XCTAssertEqual(b64.count % 4, 0)
    }

    func test_success_reply_with_padding_round_trips() {
        for n in [5, 6, 7, 8, 9] {
            let data = jpeg(n)
            let b64 = P.successReply(jpeg: data, width: 10, height: 10)["data"] as? String
            XCTAssertEqual(b64.flatMap { Data(base64Encoded: $0) }, data, "n=\(n)")
        }
    }

    func test_malformed_encoder_output_is_a_render_error() {
        func reason(_ d: Data, w: Int = 10, h: Int = 10) -> String? {
            P.successReply(jpeg: d, width: w, height: h)["reason"] as? String
        }
        var noSOI = jpeg(); noSOI[0] = 0x00
        var noSOI3 = jpeg(); noSOI3[2] = 0x00
        var noEOI = jpeg(); noEOI[8] = 0x00
        var trailing = jpeg(); trailing.append(0x00)
        XCTAssertEqual(reason(noSOI), "render_error")
        XCTAssertEqual(reason(noSOI3), "render_error")
        XCTAssertEqual(reason(noEOI), "render_error")
        XCTAssertEqual(reason(trailing), "render_error")
        XCTAssertEqual(reason(Data()), "render_error")
        XCTAssertEqual(reason(Data([0xFF, 0xD8, 0xFF, 0xD9])), "render_error")          // n < 5
        XCTAssertEqual(reason(Data([0xFF, 0xD8, 0xFF, 0xFF])), "render_error")
    }

    func test_dimensions_over_the_caps_are_a_render_error() {
        func ok(_ w: Int, _ h: Int) -> Bool { P.successReply(jpeg: jpeg(), width: w, height: h)["ok"] as? Bool == true }
        XCTAssertTrue(ok(1, 1))
        XCTAssertTrue(ok(2560, 2560))
        XCTAssertFalse(ok(2561, 10))
        XCTAssertFalse(ok(10, 2561))
        XCTAssertFalse(ok(0, 10))
        XCTAssertFalse(ok(10, 0))
        XCTAssertFalse(ok(-1, 10))
        XCTAssertFalse(P.successReply(jpeg: jpeg(), width: 2561, height: 10)["reason"] as? String != "render_error")
    }

    func test_oversized_jpeg_is_too_large() {
        let atCap = jpeg(P.maxBytes)
        XCTAssertEqual(P.successReply(jpeg: atCap, width: 100, height: 100)["ok"] as? Bool, true)
        let over = jpeg(P.maxBytes + 1)
        let reply = P.successReply(jpeg: over, width: 100, height: 100)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["reason"] as? String, "too_large")
    }

    // MARK: - replyScript

    private let cbName = "__myraOnViewShot_7"

    func test_reply_script_refuses_a_bad_name() {
        let reply = P.failureReply(.renderError)
        XCTAssertNil(P.replyScript(callbackName: nil, reply: reply))
        XCTAssertNil(P.replyScript(callbackName: "", reply: reply))
        XCTAssertNil(P.replyScript(callbackName: "alert(1)//", reply: reply))
        XCTAssertNil(P.replyScript(callbackName: "__myraOnViewShot_7\n", reply: reply))
        XCTAssertNil(P.replyScript(callbackName: "__myraOnViewShot_7;alert(1)", reply: reply))
        XCTAssertNil(P.replyScript(callbackName: "__myraOnViewShot_\u{FF11}", reply: reply))
    }

    func test_reply_script_is_a_guarded_call_with_json_argument() throws {
        let reply = P.successReply(jpeg: jpeg(40), width: 12, height: 34)
        let script = try XCTUnwrap(P.replyScript(callbackName: cbName, reply: reply))
        let prefix = "typeof \(cbName) === \"function\" && \(cbName)("
        XCTAssertTrue(script.hasPrefix(prefix), script)
        XCTAssertTrue(script.hasSuffix(");"), script)
        let json = String(script.dropFirst(prefix.count).dropLast(2))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        XCTAssertEqual(decoded, reply as NSDictionary)
    }

    func test_reply_script_for_a_failure_parses_back() throws {
        let reply = P.failureReply(.secureView)
        let script = try XCTUnwrap(P.replyScript(callbackName: cbName, reply: reply))
        let json = String(script.dropFirst("typeof \(cbName) === \"function\" && \(cbName)(".count).dropLast(2))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        XCTAssertEqual(decoded, ["ok": false, "reason": "secure_view"] as NSDictionary)
    }

    func test_reply_script_never_embeds_untrusted_text_outside_json() throws {
        // A hostile string in the reply stays inside a JSON string literal: it decodes back byte for byte.
        let hostile = "\"});alert(1);//\u{2028}\u{2029}</script>"
        let reply: [String: Any] = ["ok": false, "reason": hostile]
        let script = try XCTUnwrap(P.replyScript(callbackName: cbName, reply: reply))
        let json = String(script.dropFirst("typeof \(cbName) === \"function\" && \(cbName)(".count).dropLast(2))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["reason"] as? String, hostile)
    }

    // MARK: - Gate

    private final class Clock { var now: TimeInterval = 100 }

    private func gate() -> (P.Gate, Clock) {
        let c = Clock()
        return (P.Gate(clock: { c.now }), c)
    }

    func test_gate_starts_then_is_busy() {
        let (g, _) = gate()
        guard case .started(let t) = g.tryStart() else { return XCTFail("first start refused") }
        XCTAssertEqual(g.inFlight, t)
        XCTAssertEqual(g.tryStart(), .busy)
        XCTAssertEqual(g.inFlight, t, "the busy request disturbed the one in flight")
    }

    func test_gate_cools_down_after_a_settle() {
        let (g, c) = gate()
        guard case .started(let t) = g.tryStart() else { return XCTFail("first start refused") }
        XCTAssertTrue(g.settle(t))
        XCTAssertNil(g.inFlight)
        XCTAssertEqual(g.tryStart(), .cooling)
        c.now += P.cooldown - 0.01
        XCTAssertEqual(g.tryStart(), .cooling)
        c.now += 0.02
        guard case .started(let t2) = g.tryStart() else { return XCTFail("start after the cooldown refused") }
        XCTAssertNotEqual(t, t2, "tokens are reused")
    }

    func test_gate_cooling_does_not_extend_itself() {
        // A refused (cooling) request is not a settle: hammering must not push the cooldown out.
        let (g, c) = gate()
        guard case .started(let t) = g.tryStart() else { return XCTFail() }
        XCTAssertTrue(g.settle(t))
        for _ in 0..<7 { c.now += 0.06; if case .started = g.tryStart() { return XCTFail("started inside the cooldown") } }
        c.now += 0.1   // 0.52 s after the settle
        guard case .started = g.tryStart() else { return XCTFail("hammering extended the cooldown") }
    }

    func test_gate_settle_is_true_exactly_once() {
        let (g, _) = gate()
        guard case .started(let t) = g.tryStart() else { return XCTFail() }
        XCTAssertTrue(g.settle(t))
        XCTAssertFalse(g.settle(t))
    }

    func test_gate_settle_of_a_wrong_token_is_false_and_keeps_the_flight() {
        let (g, _) = gate()
        guard case .started(let t) = g.tryStart() else { return XCTFail() }
        XCTAssertFalse(g.settle(t + 1))
        XCTAssertFalse(g.settle(t - 1))
        XCTAssertEqual(g.inFlight, t)
        XCTAssertTrue(g.settle(t))
    }

    func test_gate_late_settle_after_a_watchdog_settle_is_false() {
        let (g, c) = gate()
        guard case .started(let t) = g.tryStart() else { return XCTFail() }
        XCTAssertTrue(g.settle(t))                  // the watchdog
        c.now += P.cooldown + 0.1
        guard case .started(let t2) = g.tryStart() else { return XCTFail() }
        XCTAssertFalse(g.settle(t), "the late snapshot of the first capture settled")
        XCTAssertEqual(g.inFlight, t2, "the late settle released the next capture")
    }

    // MARK: - shouldDeliver

    private let owned = URL(string: "https://ai.myra.eu/chat")
    private let ownedInt = URL(string: "https://ai-int.myra.eu/")

    func test_deliver_on_the_same_document_of_an_owned_page() {
        XCTAssertTrue(P.shouldDeliver(requestDocument: 3, currentDocument: 3, currentURL: owned))
        XCTAssertTrue(P.shouldDeliver(requestDocument: 0, currentDocument: 0, currentURL: ownedInt))
    }

    func test_no_delivery_into_a_replaced_document() {
        XCTAssertFalse(P.shouldDeliver(requestDocument: 3, currentDocument: 4, currentURL: owned))
        XCTAssertFalse(P.shouldDeliver(requestDocument: 4, currentDocument: 3, currentURL: owned))
    }

    func test_no_delivery_to_a_foreign_or_missing_page() {
        XCTAssertFalse(P.shouldDeliver(requestDocument: 1, currentDocument: 1, currentURL: nil))
        XCTAssertFalse(P.shouldDeliver(requestDocument: 1, currentDocument: 1, currentURL: URL(string: "https://exfil.example/")))
        XCTAssertFalse(P.shouldDeliver(requestDocument: 1, currentDocument: 1, currentURL: URL(string: "http://ai.myra.eu/")))
        XCTAssertFalse(P.shouldDeliver(requestDocument: 1, currentDocument: 1, currentURL: URL(string: "https://ai.myra.eu.exfil.example/")))
        XCTAssertFalse(P.shouldDeliver(requestDocument: 1, currentDocument: 1, currentURL: URL(string: "about:blank")))
    }

    // MARK: - constants / caps

    func test_constants_are_the_cross_platform_contract() {
        XCTAssertEqual(P.maxLongSidePx, 2560)
        XCTAssertEqual(P.maxPixels, 8_000_000)
        XCTAssertEqual(P.maxBytes, 10 * 1024 * 1024)
        XCTAssertEqual(P.jpegQuality, 0.82, accuracy: 0.0001)
        XCTAssertEqual(P.watchdog, 1.0, accuracy: 0.0001)
        XCTAssertEqual(P.cooldown, 0.5, accuracy: 0.0001)
    }

    func test_caps_flag_literal() {
        XCTAssertEqual(P.capsJS, ", viewSnapshot: true")
    }
}
