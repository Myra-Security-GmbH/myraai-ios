import XCTest

/// AGF-6849 - unit matrix of the pure part of the APNs device-token bridge (`getDeviceToken`): the callback-name shape,
/// the reply script, the replaced-document rule, the token decision and the parked-request queue. BridgeReply.swift is
/// compiled into this logic-test bundle (no app host). The on-device proof is DeviceTokenGuards (UI tests). Mirrors the
/// Android contract of AGF-6813 (`__myraOnPushToken_<n>`).
final class DeviceTokenPolicyTests: XCTestCase {

    typealias P = DeviceTokenPolicy
    private let good = "deadbeef0123456789abcdef"

    // MARK: - callback name

    func test_name_accepts_one_to_sixteen_digits() {
        XCTAssertEqual(P.callbackName(from: "__myraOnPushToken_0"), "__myraOnPushToken_0")
        XCTAssertEqual(P.callbackName(from: "__myraOnPushToken_1730000000000"), "__myraOnPushToken_1730000000000")
        XCTAssertEqual(P.callbackName(from: "__myraOnPushToken_1234567890123456"), "__myraOnPushToken_1234567890123456")
    }

    func test_name_rejects_everything_else() {
        let bad: [String] = [
            "", "__myraOnPushToken_", "__myraOnPushToken_12345678901234567",            // empty suffix, 17 digits
            "__myraOnPushToken_1\n", "__myraOnPushToken_1 ", " __myraOnPushToken_1", "\n__myraOnPushToken_1",
            "__myraOnPushToken_1;alert(1)", "__myraOnPushToken_1(0)", "__myraOnPushToken_-1", "__myraOnPushToken_0x1",
            "__myraOnPushToken_\u{0663}", "__myraOnPushToken_1\u{0663}", "__myraOnPushToken_\u{FF11}",   // Unicode digits
            "__myraOnViewShot_1", "__myraOnNotifPerm_1", "__myraOnPushToken1", "myraOnPushToken_1", "x",
            "__MYRAONPUSHTOKEN_1", "__myraOnPushToken_1\u{0}",
        ]
        for name in bad {
            XCTAssertNil(P.callbackName(from: name), "accepted: \(name.debugDescription)")
        }
    }

    func test_name_rejects_non_strings() {
        XCTAssertNil(P.callbackName(from: nil))
        XCTAssertNil(P.callbackName(from: 42))
        XCTAssertNil(P.callbackName(from: ["__myraOnPushToken_1"]))
        XCTAssertNil(P.callbackName(from: ["a": "__myraOnPushToken_1"]))
        XCTAssertNil(P.callbackName(from: NSNull()))
        XCTAssertNil(P.callbackName(from: true))
    }

    func test_name_prefixes_do_not_cross_between_bridges() {
        XCTAssertNil(P.callbackName(from: "__myraOnViewShot_7"))
        XCTAssertNil(ViewShotPolicy.callbackName(from: "__myraOnPushToken_7"))
        XCTAssertNil(BridgeReply.callbackName(from: "__myraOnPushToken_7", prefix: "__myraOnViewShot_"))
    }

    // MARK: - token validity and the decision

    func test_token_validity() {
        XCTAssertTrue(P.isValidToken(good))
        XCTAssertTrue(P.isValidToken(String(repeating: "a", count: 64)))
        XCTAssertTrue(P.isValidToken(String(repeating: "f", count: 200)))
        for bad in ["", String(repeating: "a", count: 201), "DEADBEEF", "xyz", "ab cd", "ab\n", "\u{0661}", "ab\"cd", "0x12"] {
            XCTAssertFalse(P.isValidToken(bad), "accepted: \(bad.debugDescription)")
        }
    }

    func test_decide_per_state() {
        XCTAssertEqual(P.decide(.pending), .park)
        XCTAssertEqual(P.decide(.failed), .reply(nil))
        XCTAssertEqual(P.decide(.available(good)), .reply(good))
        XCTAssertEqual(P.decide(.available("")), .reply(nil))
        XCTAssertEqual(P.decide(.available("not hex!\"")), .reply(nil))
    }

    // MARK: - reply script

    func test_script_token_is_a_guarded_call_with_a_json_string() throws {
        let s = try XCTUnwrap(P.replyScript(callbackName: "__myraOnPushToken_5", token: good))
        XCTAssertEqual(s, "typeof __myraOnPushToken_5 === \"function\" && __myraOnPushToken_5(\"\(good)\");")
    }

    func test_script_null_when_there_is_no_token() throws {
        let s = try XCTUnwrap(P.replyScript(callbackName: "__myraOnPushToken_5", token: nil))
        XCTAssertEqual(s, "typeof __myraOnPushToken_5 === \"function\" && __myraOnPushToken_5(null);")
    }

    func test_script_refuses_a_bad_name() {
        for name in [nil, "", "alert(1)//", "__myraOnPushToken_5\n", "__myraOnPushToken_5;x", "__myraOnViewShot_5"] as [String?] {
            XCTAssertNil(P.replyScript(callbackName: name, token: good), "built a script for \(String(describing: name))")
            XCTAssertNil(P.replyScript(callbackName: name, token: nil))
        }
    }

    func test_bridge_script_escapes_a_hostile_string_and_line_separators() throws {
        let hostile = "\"});alert(1);//\u{2028}\u{2029}\\\u{0}</script>"
        let s = try XCTUnwrap(BridgeReply.script(callbackName: "__myraOnPushToken_9", prefix: P.prefix, argument: .string(hostile)))
        XCTAssertFalse(s.contains("\u{2028}"))
        XCTAssertFalse(s.contains("\u{2029}"))
        XCTAssertTrue(s.contains("\\u2028") && s.contains("\\u2029"))
        // The only unescaped quote pair is the argument's own: the string cannot terminate early.
        let arg = String(s.dropFirst("typeof __myraOnPushToken_9 === \"function\" && __myraOnPushToken_9(".count).dropLast(2))
        let data = try XCTUnwrap(arg.data(using: .utf8))
        let back = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
        XCTAssertEqual(back, hostile)
    }

    func test_bridge_script_object_and_nan() throws {
        let ok = try XCTUnwrap(BridgeReply.script(callbackName: "__myraOnPushToken_1", prefix: P.prefix,
                                                  argument: .object(["ok": true])))
        XCTAssertEqual(ok, "typeof __myraOnPushToken_1 === \"function\" && __myraOnPushToken_1({\"ok\":true});")
        // NaN would raise an uncatchable Objective-C exception inside JSONSerialization: refused up front.
        XCTAssertNil(BridgeReply.script(callbackName: "__myraOnPushToken_1", prefix: P.prefix,
                                        argument: .object(["x": Double.nan])))
        XCTAssertNil(BridgeReply.script(callbackName: "__myraOnPushToken_1", prefix: P.prefix,
                                        argument: .object(["x": Double.infinity])))
    }

    func test_bridge_script_null() throws {
        let s = try XCTUnwrap(BridgeReply.script(callbackName: "__myraOnPushToken_1", prefix: P.prefix, argument: .null))
        XCTAssertTrue(s.hasSuffix("(null);"))
    }

    // MARK: - replaced-document rule

    func test_should_deliver_table() {
        let spa = URL(string: "https://ai.myra.eu/chat")
        let int = URL(string: "https://ai-int.myra.eu/")
        let api = URL(string: "https://ai-api.myra.eu/")
        let evil = URL(string: "https://evil.example/")
        XCTAssertTrue(BridgeReply.shouldDeliver(requestDocument: 3, currentDocument: 3, currentURL: spa))
        XCTAssertTrue(BridgeReply.shouldDeliver(requestDocument: 3, currentDocument: 3, currentURL: int))
        XCTAssertFalse(BridgeReply.shouldDeliver(requestDocument: 3, currentDocument: 4, currentURL: spa))
        XCTAssertFalse(BridgeReply.shouldDeliver(requestDocument: 4, currentDocument: 3, currentURL: spa))
        XCTAssertFalse(BridgeReply.shouldDeliver(requestDocument: 3, currentDocument: 3, currentURL: api))
        XCTAssertFalse(BridgeReply.shouldDeliver(requestDocument: 3, currentDocument: 3, currentURL: evil))
        XCTAssertFalse(BridgeReply.shouldDeliver(requestDocument: 3, currentDocument: 3, currentURL: nil))
    }

    // MARK: - parked requests

    func test_park_up_to_eight_then_full() {
        var q = P.Pending()
        for i in 1...8 {
            XCTAssertEqual(q.park(name: "__myraOnPushToken_\(i)", document: 1, currentDocument: 1), .parked)
        }
        XCTAssertEqual(q.count, 8)
        XCTAssertEqual(q.park(name: "__myraOnPushToken_9", document: 1, currentDocument: 1), .full)
        XCTAssertEqual(q.count, 8)
    }

    func test_drain_returns_arrival_order_and_empties() {
        var q = P.Pending()
        _ = q.park(name: "__myraOnPushToken_1", document: 5, currentDocument: 5)
        _ = q.park(name: "__myraOnPushToken_2", document: 5, currentDocument: 5)
        let all = q.drain()
        XCTAssertEqual(all.map { $0.name }, ["__myraOnPushToken_1", "__myraOnPushToken_2"])
        XCTAssertEqual(all.map { $0.document }, [5, 5])
        XCTAssertEqual(q.count, 0)
        XCTAssertTrue(q.drain().isEmpty)
    }

    func test_park_evicts_entries_of_other_documents_first() {
        var q = P.Pending()
        for i in 1...8 { _ = q.park(name: "__myraOnPushToken_\(i)", document: 1, currentDocument: 1) }
        // The page was replaced: the 8 old entries are gone, the new document can park again.
        XCTAssertEqual(q.park(name: "__myraOnPushToken_20", document: 2, currentDocument: 2), .parked)
        XCTAssertEqual(q.count, 1)
        XCTAssertEqual(q.drain().map { $0.name }, ["__myraOnPushToken_20"])
    }

    func test_park_for_a_document_that_is_not_current_is_not_parked() {
        var q = P.Pending()
        XCTAssertEqual(q.park(name: "__myraOnPushToken_1", document: 1, currentDocument: 2), .full)
        XCTAssertEqual(q.count, 0)
    }
}
