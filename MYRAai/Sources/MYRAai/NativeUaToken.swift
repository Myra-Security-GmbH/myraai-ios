import Foundation

/// AGF-7213: the `MYRAai-iOS/...` User-Agent token (WKWebViewConfiguration.applicationNameForUserAgent). Pure
/// (Foundation only, no UIKit) so the logic-test bundle can run it against the shared contract fixture
/// tests/fixtures/native_ua_token_cases.json (grammar + PRODUCER RULES in its `_header`); the server parser
/// (feedback_context.tl, derive_native_os) is the trust boundary and stays the only parser. Producer twin:
/// NativeUaToken.kt (Android).
///
/// Every input is OS-provided (utsname, UIDevice, kern.osversion, Info.plist) and treated as hostile, so each one is
/// sanitised so that this producer never triggers the server's `_native_os_invalid` marker:
///  - every Unicode SCALAR outside the field's ASCII class becomes one `_` (never iterate `Character`s: Swift
///    Strings are grapheme-based, a flag emoji or a combining mark must give one `_` per scalar like Kotlin code points),
///  - every `MYRAai-` becomes `MYRAai_` (the server rejects a UA with a second `MYRAai-`),
///  - then the value is cut to the field's maximum (class is ASCII, so chars == bytes). A cut only removes trailing
///    characters, so it can never re-create `MYRAai-`.
/// Absent and malformed are different outcomes: a core field falls back to `unknown`, an optional segment is omitted,
/// an off-class head field falls back to `0`.
enum NativeUaToken {

    private static let mark = "MYRAai-"
    private static let markSafe = "MYRAai_"

    private static func inClass(_ v: UInt32, allowDot: Bool, allowComma: Bool) -> Bool {
        switch v {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2D: return true   // A-Z a-z 0-9 _ -
        case 0x2E: return allowDot                                             // .
        case 0x2C: return allowComma                                           // ,
        default: return false
        }
    }

    /// Replace -> neutralise `MYRAai-` -> cut. nil input yields "".
    static func sanitize(_ raw: String?, allowDot: Bool, allowComma: Bool = false, max: Int) -> String {
        guard let raw = raw else { return "" }
        var out = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if inClass(scalar.value, allowDot: allowDot, allowComma: allowComma) {
                out.append(scalar)
            } else {
                out.append("_")
            }
        }
        let safe = String(out).replacingOccurrences(of: mark, with: markSafe)
        return String(safe.unicodeScalars.prefix(max))
    }

    private static func orUnknown(_ s: String) -> String { s.isEmpty ? "unknown" : s }

    /// Head version: `^[0-9][0-9.]*$`, <= 32 ASCII chars, else "0" (an off-class head makes the server drop the
    /// whole native_os; the OS facts are worth more than a misconfigured version string).
    private static func headVersion(_ raw: String?) -> String {
        guard let raw = raw else { return "0" }
        let b = Array(raw.utf8)
        guard !b.isEmpty, b.count <= 32, b[0] >= 0x30, b[0] <= 0x39 else { return "0" }
        for c in b where !((c >= 0x30 && c <= 0x39) || c == 0x2E) { return "0" }
        return raw
    }

    /// Head build: ASCII digits only, 1..10, else "0".
    private static func headBuild(_ raw: String?) -> String {
        guard let raw = raw else { return "0" }
        let b = Array(raw.utf8)
        guard !b.isEmpty, b.count <= 10 else { return "0" }
        for c in b where !(c >= 0x30 && c <= 0x39) { return "0" }
        return raw
    }

    /// The token only (the applicationName), no leading space. `osBuild` nil / empty -> no `build=` segment.
    static func token(version: String?, build: String?, machine: String?, systemVersion: String?,
                      osBuild: String?) -> String {
        let device = orUnknown(sanitize(machine, allowDot: true, allowComma: true, max: 128))
        let osVer = orUnknown(sanitize(systemVersion, allowDot: true, max: 32))
        var t = "\(mark)iOS/\(headVersion(version)) (\(headBuild(build))) \(device) / iOS \(osVer) / arm64e"
        let b = sanitize(osBuild, allowDot: true, max: 64)
        if !b.isEmpty { t += " / build=\(b)" }
        return t
    }
}
