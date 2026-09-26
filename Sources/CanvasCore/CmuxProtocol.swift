import Foundation

/// A cmux v2 failure, sent as `{"id","ok":false,"error":{"code","message"}}`.
public struct CmuxError: Error, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    static func invalidParams(_ message: String) -> CmuxError { CmuxError("invalid_params", message) }
}

/// `document.readyState` a wait accepts: `interactive` is satisfied by `complete` too.
public enum CmuxLoadState: String, Sendable {
    case interactive, complete
}

public enum CmuxWaitCondition: Equatable, Sendable {
    case loadState(CmuxLoadState)
    case urlContains(String)
    case selector(String)
}

/// Element actions that take only a selector: a CSS selector or a snapshot ref (`@e3`).
public enum CmuxElementAction: String, Sendable, CaseIterable {
    case click, dblclick, hover, focus, check, uncheck
    case scrollIntoView = "scroll_into_view"
}

/// A validated request against one browser surface: the subset of cmux's browser methods that
/// omp's cmux backend sends (`src/tools/browser/cmux/cmux-tab.ts`).
public enum CmuxBrowserCommand: Equatable, Sendable {
    case navigate(url: String)
    case back, forward, reload
    case urlGet
    case eval(script: String)
    case snapshot(interactive: Bool, maxDepth: Int?)
    case screenshot
    case element(CmuxElementAction, selector: String)
    case type(selector: String, text: String)
    case fill(selector: String, text: String)
    case press(key: String)
    case scroll(dx: Double, dy: Double)
    case wait(CmuxWaitCondition, timeoutMs: Int)

    static let defaultWaitMs = 30_000
    /// Longest wait a client can ask for; the socket connection is blocked meanwhile.
    static let maxWaitMs = 600_000

    /// The command for a surface-scoped browser method, or nil if `method` isn't one.
    public static func parse(method: String, params: JSONValue) throws -> CmuxBrowserCommand? {
        guard method.hasPrefix("browser."), method != "browser.open_split" else { return nil }
        let name = String(method.dropFirst("browser.".count))
        if let action = CmuxElementAction(rawValue: name) {
            return .element(action, selector: try string(params, "selector"))
        }
        switch name {
        case "navigate": return .navigate(url: try url(params))
        case "back": return .back
        case "forward": return .forward
        case "reload": return .reload
        case "url.get": return .urlGet
        case "eval": return .eval(script: try string(params, "script"))
        case "snapshot":
            return .snapshot(interactive: try optional(params, "interactive", \.bool) ?? false,
                             maxDepth: try optional(params, "max_depth", \.number).map { max(1, Int($0)) })
        case "screenshot": return .screenshot
        case "type": return .type(selector: try string(params, "selector"), text: try string(params, "text", allowEmpty: true))
        case "fill": return .fill(selector: try string(params, "selector"), text: try string(params, "text", allowEmpty: true))
        case "press": return .press(key: try string(params, "key"))
        case "scroll":
            return .scroll(dx: try optional(params, "dx", \.number) ?? 0, dy: try optional(params, "dy", \.number) ?? 0)
        case "wait": return try wait(params)
        default: return nil
        }
    }

    private static func wait(_ params: JSONValue) throws -> CmuxBrowserCommand {
        var conditions: [CmuxWaitCondition] = []
        if let state = try optional(params, "load_state", \.string) {
            guard let loadState = CmuxLoadState(rawValue: state) else {
                throw CmuxError.invalidParams("load_state must be \"interactive\" or \"complete\", not \"\(state)\"")
            }
            conditions.append(.loadState(loadState))
        }
        if let fragment = try optional(params, "url_contains", \.string) { conditions.append(.urlContains(fragment)) }
        if let selector = try optional(params, "selector", \.string) { conditions.append(.selector(selector)) }
        guard conditions.count == 1 else {
            throw CmuxError.invalidParams("browser.wait takes exactly one of load_state, url_contains, selector")
        }
        let timeout = try optional(params, "timeout_ms", \.number).map { Int($0) } ?? defaultWaitMs
        guard timeout >= 0 else { throw CmuxError.invalidParams("timeout_ms must not be negative") }
        return .wait(conditions[0], timeoutMs: min(timeout, maxWaitMs))
    }

    private static func url(_ params: JSONValue) throws -> String {
        let raw = try string(params, "url")
        guard let url = BrowserURL.normalize(raw) else { throw CmuxError.invalidParams("not a URL: \(raw)") }
        return url.absoluteString
    }

    static func string(_ params: JSONValue, _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = try optional(params, key, \.string) else { throw CmuxError.invalidParams("missing \(key)") }
        guard allowEmpty || !value.isEmpty else { throw CmuxError.invalidParams("\(key) must not be empty") }
        return value
    }

    /// A present key must have the right type; absent and null mean "not given".
    static func optional<T>(_ params: JSONValue, _ key: String, _ read: (JSONValue) -> T?) throws -> T? {
        guard let value = params[key], value != .null else { return nil }
        guard let typed = read(value) else { throw CmuxError.invalidParams("\(key) has the wrong type") }
        return typed
    }
}

/// What a browser tile loads for a typed address or an agent-supplied URL.
public enum BrowserURL {
    static let schemes: Set<String> = ["http", "https", "about", "file", "data"]

    /// Full URLs pass through; bare hosts get a scheme (http for local hosts, https otherwise).
    /// Text that isn't an address (spaces, no dot or port) returns nil.
    public static func normalize(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) {
            let opaque = scheme == "about" || scheme == "data"
            return opaque || url.host != nil || scheme == "file" ? url : nil
        }
        guard let candidate = URL(string: "http://" + text), let host = candidate.host?.lowercased() else { return nil }
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.allSatisfy { $0.isNumber || $0 == "." } || host.hasPrefix("[")
        guard local || host.contains(".") else { return candidate.port != nil ? candidate : nil }
        return local ? candidate : URL(string: "https://" + text)
    }
}
