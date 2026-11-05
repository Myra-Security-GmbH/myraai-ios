import Foundation

// RED STUB (AGF-6849): compiles, answers permissively / wrongly. Replaced by the real implementation in the next commit.

enum BridgeReply {
    enum Argument {
        case object([String: Any])
        case string(String)
        case null
    }

    static func callbackName(from body: Any?, prefix: String) -> String? { body as? String }

    static func script(callbackName name: String?, prefix: String, argument: Argument) -> String? { nil }

    static func shouldDeliver(requestDocument: Int, currentDocument: Int, currentURL: URL?) -> Bool { true }
}

@MainActor
final class PageIdentity {
    private(set) var generation = 0

    func documentCommitted() {
        generation += 1
    }
}

enum DeviceTokenPolicy {
    static let prefix = "__myraOnPushToken_"
    static let maxParked = 8

    enum TokenState: Equatable {
        case pending
        case available(String)
        case failed
    }

    enum Action: Equatable {
        case reply(String?)
        case park
    }

    static func callbackName(from body: Any?) -> String? { BridgeReply.callbackName(from: body, prefix: prefix) }

    static func isValidToken(_ token: String) -> Bool { true }

    static func decide(_ state: TokenState) -> Action { .park }

    static func replyScript(callbackName name: String?, token: String?) -> String? { nil }

    struct Pending {
        enum Park: Equatable {
            case parked
            case full
        }

        private(set) var entries: [(name: String, document: Int)] = []

        var count: Int { entries.count }

        mutating func park(name: String, document: Int, currentDocument: Int) -> Park { .parked }

        mutating func drain() -> [(name: String, document: Int)] { [] }
    }
}
