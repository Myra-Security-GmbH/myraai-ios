import XCTest

/// AGF-5944 — the last-deeplink crumb (`window.__myraLastDeeplink`): the outcome classification, the route class
/// (contract table `last_deeplink_route_cases.json`, bundled copy), the crumb JS and the owned-page predicate.
/// The URL is untrusted: only enum wire values and a clamped number may reach the JS.
final class DeepLinkCrumbTests: XCTestCase {

    private func url(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> URL {
        guard let u = URL(string: raw) else {
            XCTFail("test URL does not parse: \(raw)", file: file, line: line)
            return URL(fileURLWithPath: "/")
        }
        return u
    }

    private func fixture(_ name: String) throws -> [[String: Any]] {
        let bundle = Bundle(for: DeepLinkCrumbTests.self)
        let fileURL: URL = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "fixture \(name).json is not in the test bundle")
        let data: Data = try Data(contentsOf: fileURL)
        let parsed: Any = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(parsed as? [[String: Any]])
    }

    // MARK: outcome

    func test_outcome_table() {
        let rows: [(String, NavigationPolicy.UniversalLinkOutcome)] = [
            ("https://ai.myra.eu/shared/x", .loaded),
            ("HTTPS://AI.MYRA.EU/shared/x", .loaded),
            ("https://x.ai.myra.eu/shared/x", .loaded),
            ("https://evil.com@ai.myra.eu/x", .loaded),
            ("http://ai.myra.eu/x", .droppedScheme),
            ("myraai://ai.myra.eu/shared/x", .droppedScheme),
            ("javascript:alert(1)", .droppedScheme),
            ("https://evil.com/", .droppedHost),
            ("https://ai.myra.eu@evil.com/x", .droppedHost),
            ("https://ai.myra.eu.evil.com/x", .droppedHost),
            ("https://ai-int.myra.eu/x", .droppedHost),
            ("https://evil.example/auth/app-complete", .droppedHost),
            ("https:///no-host", .droppedHost),
            ("https://ai.myra.eu/auth/app-complete", .droppedAppComplete),
            ("https://ai.myra.eu/auth/app-complete?x=1#y", .droppedAppComplete),
            ("https://ai.myra.eu/auth/%61pp-complete", .droppedAppComplete),
        ]
        for (raw, expected) in rows {
            XCTAssertEqual(NavigationPolicy.universalLinkOutcome(url(raw)), expected, raw)
        }
    }

    func test_target_is_the_loaded_outcome() {
        // expectLoad is written out per row (independent of universalLinkOutcome): the target is the URL itself or nil.
        let gateTable: [(String, Bool)] = [
            ("https://ai.myra.eu/shared/x", true), ("https://ai.myra.eu/auth/verify?a=1#token=t", true),
            ("HTTPS://AI.MYRA.EU/shared/x", true), ("https://eu.ai.myra.eu/x", true),
            ("https://evil.com@ai.myra.eu/x", true), ("https://x.ai.myra.eu/shared/x", true),
            ("http://ai.myra.eu/shared/x", false), ("myraai://ai.myra.eu/shared/x", false),
            ("javascript:alert(1)", false), ("file:///etc/passwd", false), ("ai.myra.eu/shared/x", false),
            ("https://evil.com/", false), ("https://ai.myra.eu.evil.com/", false), ("https://evilai.myra.eu.com/", false),
            ("https://xai.myra.eu/", false), ("https://ai.myra.eu@evil.com/", false), ("https://myra.eu/", false),
            ("https://ai-int.myra.eu/x", false), ("https://ai-api-admin.myra.eu/x", false), ("https://ai-api.myra.eu/x", false),
            ("https://ai.myra.eu/auth/app-complete", false), ("https://ai.myra.eu/auth/app-complete?x=1#y", false),
            ("https://ai.myra.eu/auth/app-complete/", false), ("https://ai.myra.eu/auth/%61pp-complete", false),
            ("http://ai.myra.eu/x", false), ("https://evil.example/auth/app-complete", false),
        ]
        for (raw, expectLoad) in gateTable {
            let u: URL = url(raw)
            let expected: URL? = expectLoad ? u : nil
            XCTAssertEqual(NavigationPolicy.universalLinkTarget(u), expected, raw)
        }
    }

    // MARK: route class

    func test_route_table_from_the_bundled_contract_fixture() throws {
        let rows: [[String: Any]] = try fixture("last_deeplink_route_cases")
        XCTAssertGreaterThan(rows.count, 0, "an empty route table must fail, not pass vacuously")
        var checked: Int = 0
        for row in rows {
            let expectedRoute: String = try XCTUnwrap(row["route"] as? String)
            let rawPath: String? = row["path"] as? String   // JSON null (NSNull) -> nil
            XCTAssertEqual(NavigationPolicy.routeClass(rawPath: rawPath).rawValue, expectedRoute, "path=\(String(describing: rawPath))")
            checked += 1
        }
        XCTAssertEqual(checked, rows.count)
    }

    func test_route_class_uses_the_raw_path_not_the_decoded_one() {
        XCTAssertEqual(NavigationPolicy.routeClass(of: url("https://ai.myra.eu/%73hared/x")), .other)
        XCTAssertEqual(NavigationPolicy.routeClass(of: url("https://ai.myra.eu/shared/x")), .shared)
        XCTAssertEqual(NavigationPolicy.routeClass(of: url("https://ai.myra.eu/shared?x=1#f")), .shared)
        XCTAssertEqual(NavigationPolicy.routeClass(of: url("https://ai.myra.eu/easy/c/abc")), .c)
        XCTAssertEqual(NavigationPolicy.routeClass(of: url("https://ai.myra.eu")), .other)
        XCTAssertEqual(NavigationPolicy.routeClass(of: nil), .other)
    }

    func test_huge_garbage_path_is_other() {
        let huge: String = "/" + String(repeating: "\u{0}x%zz", count: 20000)
        XCTAssertEqual(NavigationPolicy.routeClass(rawPath: huge), .other)
    }

    // MARK: crumb JS

    func test_crumb_js_exact_output() {
        let js: String = NavigationPolicy.crumbJS(receivedAt: Date(timeIntervalSince1970: 1700000000), via: .openURL,
                                                  route: .shared, outcome: .loaded)
        XCTAssertEqual(js, "window.__myraLastDeeplink={\"received_at_ms\":1700000000000,\"via\":\"openURL\","
                       + "\"route\":\"shared\",\"outcome\":\"loaded\"};")
    }

    func test_crumb_js_shape_for_every_enum_combination() throws {
        let vias: [NavigationPolicy.CrumbVia] = [.openURL, .activity]
        let routes: [NavigationPolicy.CrumbRoute] = [.shared, .auth, .c, .other]
        let outcomes: [NavigationPolicy.UniversalLinkOutcome] = [.loaded, .droppedScheme, .droppedHost, .droppedAppComplete]
        let regex = try NSRegularExpression(pattern:
            "^window\\.__myraLastDeeplink=\\{\"received_at_ms\":[0-9]+,\"via\":\"(openURL|activity)\","
            + "\"route\":\"(shared|auth|c|other)\","
            + "\"outcome\":\"(loaded|dropped_scheme|dropped_host|dropped_app_complete)\"\\};$")
        for via in vias {
            for route in routes {
                for outcome in outcomes {
                    let js: String = NavigationPolicy.crumbJS(receivedAt: Date(), via: via, route: route, outcome: outcome)
                    let range = NSRange(js.startIndex..., in: js)
                    XCTAssertNotNil(regex.firstMatch(in: js, options: [], range: range), js)
                    XCTAssertFalse(js.contains("/"), js)
                    XCTAssertFalse(js.contains("?"), js)
                    XCTAssertFalse(js.contains("#"), js)
                }
            }
        }
    }

    func test_crumb_js_clamps_the_clock() {
        let past: String = NavigationPolicy.crumbJS(receivedAt: .distantPast, via: .activity, route: .other, outcome: .loaded)
        let future: String = NavigationPolicy.crumbJS(receivedAt: .distantFuture, via: .activity, route: .other, outcome: .loaded)
        let nan: String = NavigationPolicy.crumbJS(receivedAt: Date(timeIntervalSince1970: Double.nan), via: .activity,
                                                   route: .other, outcome: .loaded)
        XCTAssertTrue(past.contains("\"received_at_ms\":0,"), past)
        XCTAssertTrue(future.contains("\"received_at_ms\":4102444800000,"), future)
        XCTAssertTrue(nan.contains("\"received_at_ms\":0,"), nan)
    }

    // MARK: parity with the contract's valid cases

    func test_crumb_wire_values_are_valid_contract_values() throws {
        let cases: [[String: Any]] = try fixture("last_deeplink_cases")
        XCTAssertGreaterThan(cases.count, 0)
        var vias = Set<String>(), routes = Set<String>(), outcomes = Set<String>()
        for c in cases where (c["valid"] as? Bool) == true {
            guard let value = c["value"] as? [String: Any] else { continue }
            if let v = value["via"] as? String { vias.insert(v) }
            if let r = value["route"] as? String { routes.insert(r) }
            if let o = value["outcome"] as? String { outcomes.insert(o) }
        }
        XCTAssertFalse(vias.isEmpty)
        for v in ["openURL", "activity"] { XCTAssertTrue(vias.contains(v), v) }
        for r in ["shared", "auth", "c", "other"] { XCTAssertTrue(routes.contains(r), r) }
        for o in ["loaded", "dropped_scheme", "dropped_host", "dropped_app_complete"] { XCTAssertTrue(outcomes.contains(o), o) }
        // The real crumbJS output, parsed: its keys equal a valid contract entry's keys and every value is accepted.
        let js: String = NavigationPolicy.crumbJS(receivedAt: Date(timeIntervalSince1970: 1700000000), via: .openURL,
                                                  route: .shared, outcome: .loaded)
        let prefix: String = "window.__myraLastDeeplink="
        XCTAssertTrue(js.hasPrefix(prefix), js)
        XCTAssertTrue(js.hasSuffix(";"), js)
        let literal: String = String(js.dropFirst(prefix.count).dropLast())
        let parsed: Any = try JSONSerialization.jsonObject(with: Data(literal.utf8))
        let obj: [String: Any] = try XCTUnwrap(parsed as? [String: Any], literal)
        let validValues: [[String: Any]] = cases.filter { ($0["valid"] as? Bool) == true }.compactMap { $0["value"] as? [String: Any] }
        let contractKeys: Set<String>? = validValues.map { Set($0.keys) }.first { $0.contains("via") && $0.contains("route") }
        XCTAssertEqual(Set(obj.keys), try XCTUnwrap(contractKeys, "no full valid object entry in the contract fixture"))
        XCTAssertTrue(vias.contains(try XCTUnwrap(obj["via"] as? String)))
        XCTAssertTrue(routes.contains(try XCTUnwrap(obj["route"] as? String)))
        XCTAssertTrue(outcomes.contains(try XCTUnwrap(obj["outcome"] as? String)))
        let ms: Double = try XCTUnwrap((obj["received_at_ms"] as? NSNumber)?.doubleValue)
        XCTAssertGreaterThanOrEqual(ms, 0)
        XCTAssertLessThanOrEqual(ms, 4102444800000)
        XCTAssertEqual(NavigationPolicy.CrumbVia.openURL.rawValue, "openURL")
        XCTAssertEqual(NavigationPolicy.CrumbVia.activity.rawValue, "activity")
        XCTAssertEqual(NavigationPolicy.UniversalLinkOutcome.droppedAppComplete.rawValue, "dropped_app_complete")
    }

    // MARK: owned page

    func test_owned_spa_page_predicate() {
        XCTAssertTrue(NavigationPolicy.isOwnedSPAPage(url("https://ai.myra.eu/")))
        XCTAssertTrue(NavigationPolicy.isOwnedSPAPage(url("https://ai-int.myra.eu/")))
        XCTAssertFalse(NavigationPolicy.isOwnedSPAPage(url("https://ai.myra.eu:443/")))
        XCTAssertFalse(NavigationPolicy.isOwnedSPAPage(url("http://ai.myra.eu/")))
        XCTAssertFalse(NavigationPolicy.isOwnedSPAPage(url("https://ai-api.myra.eu/")))
        XCTAssertFalse(NavigationPolicy.isOwnedSPAPage(url("https://x.ai.myra.eu/")))
        XCTAssertFalse(NavigationPolicy.isOwnedSPAPage(nil))
    }
}
