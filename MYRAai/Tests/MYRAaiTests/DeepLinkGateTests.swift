import XCTest

/// AGF-5758 — the gate table of `NavigationPolicy.universalLinkTarget`, the ONE gate a tapped universal link passes
/// before it is loaded into the app's web view (`ContentView.openDeepLink`). The URL is untrusted input: BAD input
/// is rejected (nil), only our own https hosts load. The on-simulator proof of the delivery is `DeepLinkGuards`.
final class DeepLinkGateTests: XCTestCase {

    private func target(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> URL? {
        guard let url = URL(string: raw) else {
            XCTFail("test URL does not parse: \(raw)", file: file, line: line)
            return nil
        }
        return NavigationPolicy.universalLinkTarget(url)
    }

    // MARK: loads

    func test_owned_https_link_loads_unchanged() {
        XCTAssertEqual(target("https://ai.myra.eu/shared/x")?.absoluteString, "https://ai.myra.eu/shared/x")
    }

    func test_fragment_and_query_ride_along() {
        XCTAssertEqual(target("https://ai.myra.eu/auth/verify?a=1#token=t")?.absoluteString,
                       "https://ai.myra.eu/auth/verify?a=1#token=t")
    }

    func test_scheme_and_host_are_case_insensitive() {
        XCTAssertNotNil(target("HTTPS://AI.MYRA.EU/shared/x"))
    }

    func test_subdomain_of_the_app_host_loads() {
        XCTAssertNotNil(target("https://eu.ai.myra.eu/x"))
    }

    func test_userinfo_is_not_the_host() {
        // host is ai.myra.eu, the userinfo is stripped by URL
        XCTAssertNotNil(target("https://evil.com@ai.myra.eu/x"))
    }

    // MARK: dropped

    func test_http_is_dropped() {
        XCTAssertNil(target("http://ai.myra.eu/shared/x"))
    }

    func test_other_schemes_are_dropped() {
        for raw in ["myraai://ai.myra.eu/shared/x", "javascript:alert(1)", "file:///etc/passwd", "ai.myra.eu/shared/x"] {
            XCTAssertNil(target(raw), raw)
        }
    }

    func test_foreign_host_is_dropped() {
        XCTAssertNil(target("https://evil.com/"))
    }

    func test_lookalike_hosts_are_dropped() {
        for raw in ["https://ai.myra.eu.evil.com/", "https://evilai.myra.eu.com/", "https://xai.myra.eu/",
                    "https://ai.myra.eu@evil.com/", "https://myra.eu/"] {
            XCTAssertNil(target(raw), raw)
        }
    }

    func test_other_owned_hosts_keep_todays_behaviour_and_are_dropped() {
        // the gate's host set is ai.myra.eu + subdomains only (not NavigationPolicy.ownedHosts)
        for raw in ["https://ai-int.myra.eu/x", "https://ai-api-admin.myra.eu/x", "https://ai-api.myra.eu/x"] {
            XCTAssertNil(target(raw), raw)
        }
    }

    func test_app_complete_is_dropped() {
        for raw in ["https://ai.myra.eu/auth/app-complete", "https://ai.myra.eu/auth/app-complete?x=1#y",
                    "https://ai.myra.eu/auth/app-complete/", "https://ai.myra.eu/auth/%61pp-complete"] {
            XCTAssertNil(target(raw), raw)
        }
    }
}
