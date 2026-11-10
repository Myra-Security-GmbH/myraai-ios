import XCTest
#if SWIFT_PACKAGE
@testable import MYRAai
#endif

/// AGF-7213 — NativeUaToken (the source file is compiled into this logic-test bundle; Foundation only, no app host).
/// Contract: tests/fixtures/native_ua_token_cases.json (byte copy under Fixtures/, lint_ios_route_fixture_sync.sh).
/// The on-device proof that the real WKWebView UA carries exactly one token is DeviceTokenGuards (UI tests).
final class NativeUaTokenTests: XCTestCase {

    private typealias T = NativeUaToken

    private func tok(version: String? = "1.0.15", build: String? = "10", machine: String? = "iPhone15,2",
                     system: String? = "18.1", osBuild: String? = "22B83") -> String {
        T.token(version: version, build: build, machine: machine, systemVersion: system, osBuild: osBuild)
    }

    // MARK: fixture

    private func loadCases() throws -> [[String: Any]] {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: "native_ua_token_cases", withExtension: "json"),
                                "fixture missing from the test bundle")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(obj as? [String: Any])
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }

    private func str(_ v: Any?) -> String? { v as? String }   // JSON null (NSNull) -> nil

    func test_fixture_parity_with_producer_cases() throws {
        var n = 0
        for c in try loadCases() {
            guard let ios = c["ios"] as? [String: Any] else { continue }
            let name = c["name"] as? String ?? "?"
            n += 1
            let defaultUa = try XCTUnwrap(ios["default_ua"] as? String, name)
            let ua = try XCTUnwrap(c["ua"] as? String, name)
            XCTAssertTrue(ua.hasPrefix(defaultUa + " "), "\(name): ua must start with default_ua + space")
            let want = String(ua.dropFirst(defaultUa.count + 1))
            let got = T.token(version: str(ios["version"]), build: str(ios["build"]), machine: str(ios["machine"]),
                              systemVersion: str(ios["system_version"]), osBuild: str(ios["os_build"]))
            XCTAssertEqual(got, want, name)
            // The producer never triggers the server's invalid marker: expect is a native_os object, no `invalid`.
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], "\(name): expect must be an object")
            XCTAssertNotNil(expect["native_os"] as? [String: Any], name)
            XCTAssertNil(expect["invalid"], "\(name): a producer case must not expect invalid")
        }
        XCTAssertGreaterThanOrEqual(n, 8, "fixture lost its iOS producer cases")
    }

    // MARK: unit cases

    func test_release_token_is_byte_identical_to_todays_prefix() {
        XCTAssertEqual(tok(), "MYRAai-iOS/1.0.15 (10) iPhone15,2 / iOS 18.1 / arm64e / build=22B83")
        XCTAssertEqual(tok(osBuild: nil), "MYRAai-iOS/1.0.15 (10) iPhone15,2 / iOS 18.1 / arm64e")
    }

    func test_comma_is_kept_in_machine_only() {
        XCTAssertEqual(T.sanitize("iPhone15,2", allowDot: true, allowComma: true, max: 128), "iPhone15,2")
        XCTAssertEqual(T.sanitize("a,b", allowDot: true, max: 32), "a_b")
    }

    func test_one_underscore_per_unicode_scalar_not_per_character() {
        XCTAssertEqual(T.sanitize("\u{E9}", allowDot: true, max: 32), "_")            // precomposed e-acute
        XCTAssertEqual(T.sanitize("e\u{301}", allowDot: true, max: 32), "e_")         // e + combining acute
        XCTAssertEqual(T.sanitize("\u{1F1E9}\u{1F1EA}", allowDot: true, max: 32), "__") // flag = 2 scalars
        XCTAssertEqual(T.sanitize("\u{1F600}", allowDot: true, max: 32), "_")         // astral = 1 scalar
        XCTAssertEqual(T.sanitize("a\r\nb", allowDot: true, max: 32), "a__b")         // CRLF is ONE Character
        XCTAssertEqual(T.sanitize("\u{0}", allowDot: true, max: 32), "_")
    }

    func test_mark_is_neutralised_in_every_field() {
        let t = tok(version: "MYRAai-1", build: "MYRAai-2", machine: "MYRAai-iPhone", system: "MYRAai-18", osBuild: "MYRAai-B")
        XCTAssertEqual(t.components(separatedBy: "MYRAai-").count, 2, t)   // exactly the leading one
        XCTAssertEqual(tok(osBuild: "22B83 MYRAai-x"), "MYRAai-iOS/1.0.15 (10) iPhone15,2 / iOS 18.1 / arm64e / build=22B83_MYRAai_x")
        XCTAssertEqual(T.sanitize("MYRAai-MYRAai-", allowDot: true, max: 64), "MYRAai_MYRAai_")
        // a char that is out of class between the letters and the dash cannot forge a mark either
        XCTAssertEqual(T.sanitize("MYRAai\u{301}-", allowDot: true, max: 64), "MYRAai_-")
    }

    func test_build_segment_omitted_when_absent_or_empty() {
        XCTAssertFalse(tok(osBuild: nil).contains("build="))
        XCTAssertFalse(tok(osBuild: "").contains("build="))
        XCTAssertTrue(tok(osBuild: "x").hasSuffix(" / build=x"))
    }

    func test_core_fields_fall_back_to_unknown() {
        XCTAssertEqual(tok(machine: nil, system: nil), "MYRAai-iOS/1.0.15 (10) unknown / iOS unknown / arm64e / build=22B83")
        XCTAssertEqual(tok(machine: "", system: ""), "MYRAai-iOS/1.0.15 (10) unknown / iOS unknown / arm64e / build=22B83")
    }

    func test_head_fallbacks() {
        func head(_ v: String?, _ b: String?) -> String {
            let t = tok(version: v, build: b)
            let rest = String(t.dropFirst("MYRAai-iOS/".count))
            return rest.components(separatedBy: " iPhone15,2 / ").first ?? ""
        }
        XCTAssertEqual(head("1.0.15", "10"), "1.0.15 (10)")
        XCTAssertEqual(head("1.0.15-beta", "10"), "0 (10)")
        XCTAssertEqual(head("1.0.15", "10.1"), "1.0.15 (0)")
        XCTAssertEqual(head("\u{663}", "\u{663}"), "0 (0)")            // Arabic-indic digit three
        XCTAssertEqual(head(nil, nil), "0 (0)")
        XCTAssertEqual(head("", ""), "0 (0)")
        XCTAssertEqual(head(".1", "-1"), "0 (0)")                       // must start with a digit
        XCTAssertEqual(head("1.0\n", "10\n"), "0 (0)")                  // trailing newline is off-class
        XCTAssertEqual(head(String(repeating: "1", count: 32), "1234567890"),
                       String(repeating: "1", count: 32) + " (1234567890)")
        XCTAssertEqual(head(String(repeating: "1", count: 33), "12345678901"), "0 (0)")
    }

    func test_cuts_are_exact() {
        XCTAssertEqual(T.sanitize(String(repeating: "a", count: 40), allowDot: true, max: 32).count, 32)
        XCTAssertEqual(T.sanitize(String(repeating: "a", count: 32), allowDot: true, max: 32).count, 32)
        XCTAssertEqual(T.sanitize(String(repeating: "a", count: 31), allowDot: true, max: 32).count, 31)
        XCTAssertEqual(tok(osBuild: String(repeating: "B", count: 100)).components(separatedBy: "build=").last,
                       String(repeating: "B", count: 64))
        let dev = tok(machine: String(repeating: "m", count: 200)).components(separatedBy: " / ")[0]
        XCTAssertTrue(dev.hasSuffix(" " + String(repeating: "m", count: 128)), "device cut to 128")
        // a cut through "MYRAai-" never leaves a mark (cut only removes a tail)
        XCTAssertFalse(T.sanitize(String(repeating: "x", count: 60) + "MYRAai-", allowDot: true, max: 64).contains("MYRAai-"))
    }

    // MARK: seeded property test

    /// Deterministic LCG (no SystemRandomNumberGenerator): reproducible failures.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private let pieces: [String] = [
        " / ", "/", " ", "MYRAai-", "MYRAai_", "MYRAai", "-", "\n", "\r\n", "\0", "=", ",", ".", "_", "(", ")",
        "a", "Z", "0", "9", "22B83", "iPhone15,2", "\u{1F600}", "\u{1F1E9}\u{1F1EA}", "e\u{301}", "\u{E9}",
        "\u{202E}", "\u{200B}", "\u{663}", "\u{FF0D}", "\u{0}", "build=", "x", String(repeating: "q", count: 70),
        String(repeating: "m", count: 140),
    ]

    private func hostile(_ g: inout LCG) -> String? {
        if g.below(12) == 0 { return nil }
        var s = ""
        for _ in 0..<g.below(8) { s += pieces[g.below(pieces.count)] }
        return s
    }

    func test_property_hostile_inputs_always_produce_a_contract_token() throws {
        let head = try NSRegularExpression(pattern: "^MYRAai-iOS/[0-9][0-9.]{0,31} \\([0-9]{1,10}\\) [A-Za-z0-9._,-]{1,128}$")
        let osv = try NSRegularExpression(pattern: "^iOS [A-Za-z0-9._-]{1,32}$")
        let bld = try NSRegularExpression(pattern: "^build=[A-Za-z0-9._-]{1,64}$")
        func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
            r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        var g = LCG(state: 0x7213_A6F)
        for i in 0..<6000 {
            let t = T.token(version: hostile(&g), build: hostile(&g), machine: hostile(&g),
                            systemVersion: hostile(&g), osBuild: hostile(&g))
            XCTAssertTrue(t.hasPrefix("MYRAai-iOS/"), "#\(i) \(t)")
            XCTAssertEqual(t.components(separatedBy: "MYRAai-").count, 2, "#\(i) exactly one mark: \(t)")
            XCTAssertTrue(t.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }, "#\(i) pure printable ASCII: \(t)")
            let parts = t.components(separatedBy: " / ")
            XCTAssertTrue(parts.count == 3 || parts.count == 4, "#\(i) parts=\(parts.count): \(t)")
            guard parts.count >= 3 else { continue }
            XCTAssertTrue(matches(head, parts[0]), "#\(i) head: \(parts[0])")
            XCTAssertTrue(matches(osv, parts[1]), "#\(i) osver: \(parts[1])")
            XCTAssertEqual(parts[2], "arm64e", "#\(i)")
            if parts.count == 4 { XCTAssertTrue(matches(bld, parts[3]), "#\(i) build: \(parts[3])") }
        }
    }
}
