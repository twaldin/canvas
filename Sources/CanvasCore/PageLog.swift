import Foundation

/// One thing a browser tile's page reported: a console message, an uncaught error or unhandled
/// rejection (`exception`), or a request that failed (an HTTP status of 400 or more, a network
/// error, a resource that didn't load). `seq` orders a document's entries; `time` is ISO 8601.
public struct PageLogEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case console, exception, request
    }

    public var seq: Int
    public var time: String
    public var kind: Kind
    /// `log`, `info`, `warn`, `error` or `debug`; exceptions and failed requests are `error`.
    public var level: String
    public var text: String
    /// `url:line:column` of the code that logged or threw (warnings and errors).
    public var source: String?
    public var stack: String?
    public var method: String?
    /// A request's URL.
    public var url: String?
    /// A request's HTTP status; absent when it never got one (network error, blocked, a resource
    /// whose load failed without a status WebKit exposes).
    public var status: Int?
    /// What made the request: `fetch`, `xhr`, `document`, or the element (`img`, `script`, `link`…).
    public var resource: String?

    public init(seq: Int, time: String, kind: Kind, level: String, text: String, source: String? = nil, stack: String? = nil,
                method: String? = nil, url: String? = nil, status: Int? = nil, resource: String? = nil) {
        self.seq = seq
        self.time = time
        self.kind = kind
        self.level = level
        self.text = text
        self.source = source
        self.stack = stack
        self.method = method
        self.url = url
        self.status = status
        self.resource = resource
    }

    public var isError: Bool { level == "error" }

    /// What it is, in a word or two: `error`, `warning`, `failed request`, `console.log`.
    public var noun: String {
        switch kind {
        case .exception: "error"
        case .request: "failed request"
        case .console: level == "error" ? "console error" : level == "warn" ? "warning" : "console.\(level)"
        }
    }

    /// `app.js:12` for `http://localhost:3000/static/app.js?v=3:12:5`: the file name and line, as
    /// a person scans a list; nil without a source.
    public var shortSource: String? {
        guard let source else { return nil }
        let parts = source.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let line = Int(parts[parts.count - 2]), Int(parts[parts.count - 1]) != nil else { return PathLabel.short(source) }
        let file = parts.dropLast(2).joined(separator: ":")
        let path = URL(string: file)?.path ?? file
        // A page's own inline script: its URL without the scheme (`localhost:3000/:14`).
        let name = path.split(separator: "/").last.map(String.init) ?? file.replacingOccurrences(of: #"^[a-z]+://"#, with: "", options: .regularExpression)
        return "\(name):\(line)"
    }

    /// The time of day it happened (`14:03:05`), in the local time zone.
    public var clockTime: String? {
        guard let date = PageLog.isoFormatter.date(from: time) else { return nil }
        return PageLog.clockFormatter.string(from: date)
    }
}

/// What a browser tile's page reported since it loaded (`PageCapture` records it in the page),
/// as `object.get` returns it under `page` and the tile's problems list shows it.
public struct PageLog: Equatable, Sendable {
    /// The page's document: a new one (a load, a reload) starts a new log.
    public var document: String
    public var url: String
    /// Oldest first. Errors and warnings are kept apart from the other messages, so a chatty
    /// page's logs never push its errors out.
    public var entries: [PageLogEntry]
    /// Entries that fell out of the page's buffer.
    public var dropped: Int
    /// Since the page loaded, including dropped ones.
    public var errors: Int
    public var warnings: Int
    public var vitals: JSONValue

    /// Most entries `json` returns; the latest ones win.
    public static let returnedEntries = 100

    public init(document: String, url: String, entries: [PageLogEntry], dropped: Int = 0, errors: Int, warnings: Int, vitals: JSONValue = .null) {
        self.document = document
        self.url = url
        self.entries = entries
        self.dropped = dropped
        self.errors = errors
        self.warnings = warnings
        self.vitals = vitals
    }

    /// What `PageCapture.readScript` returns, parsed; nil when it isn't one.
    public init?(json: JSONValue) {
        guard let document = json["document"]?.string, let raw = json["entries"]?.array else { return nil }
        self.document = document
        url = json["url"]?.string ?? ""
        entries = raw.compactMap(Self.entry).sorted { $0.seq < $1.seq }
        dropped = Self.count(json["dropped"]) ?? 0
        errors = Self.count(json["errors"]) ?? 0
        warnings = Self.count(json["warnings"]) ?? 0
        vitals = Self.vitals(json["vitals"])
    }

    /// The page's own document came back with an HTTP error: the first entry, counted as an error.
    public mutating func add(documentFailure: PageLogEntry) {
        entries.insert(documentFailure, at: 0)
        errors += 1
    }

    /// Where the next read continues: pass it back as `since`.
    public var cursor: String { "\(document):\(entries.last?.seq ?? 0)" }

    /// The entries after `since` (a `cursor` of this log or an older one), at most `limit`, the
    /// latest kept; `omitted` counts the older ones left out. A cursor from an earlier document
    /// (the page reloaded since) means the whole of this one.
    public func entries(after since: Cursor?, limit: Int = PageLog.returnedEntries) -> (entries: [PageLogEntry], omitted: Int) {
        let after = since.flatMap { $0.document == document ? $0.seq : nil } ?? -1
        let newer = entries.filter { $0.seq > after }
        return (Array(newer.suffix(limit)), max(0, newer.count - limit))
    }

    /// The API's `page` object: the entries after `since`, the counts, the cursor, and the vitals.
    public func json(since: Cursor? = nil) -> JSONValue {
        let shown = entries(after: since, limit: Self.returnedEntries)
        var fields: [String: JSONValue] = [
            "loaded": .bool(true),
            "url": .string(url),
            "errors": .number(Double(errors)),
            "warnings": .number(Double(warnings)),
            "entries": (try? JSONValue.encode(shown.entries)) ?? .array([]),
            "cursor": .string(cursor),
            "vitals": vitals,
        ]
        if shown.omitted > 0 { fields["omitted"] = .number(Double(shown.omitted)) }
        if dropped > 0 { fields["dropped"] = .number(Double(dropped)) }
        if since.map({ $0.document != document }) == true { fields["reloaded"] = .bool(true) }
        return .object(fields)
    }

    /// The errors, newest first: what the tile's problems list shows.
    public var problems: [PageLogEntry] { entries.filter(\.isError).reversed() }

    /// A `cursor` as `object.get`'s `since` takes it: `<document>:<seq>`.
    public struct Cursor: Equatable, Sendable {
        public var document: String
        public var seq: Int

        public init?(_ text: String) {
            guard let colon = text.lastIndex(of: ":"), let seq = Int(text[text.index(after: colon)...]), seq >= 0 else { return nil }
            let document = String(text[..<colon])
            guard !document.isEmpty else { return nil }
            self.document = document
            self.seq = seq
        }
    }

    // MARK: Parsing the page's record

    static let maxText = 1000
    static let maxStack = 4000

    static func entry(_ raw: JSONValue) -> PageLogEntry? {
        guard let seq = count(raw["seq"]), let kind = raw["kind"]?.string.flatMap(PageLogEntry.Kind.init),
              let text = raw["text"]?.string else { return nil }
        let level = raw["level"]?.string ?? (kind == .console ? "log" : "error")
        let millis = raw["time"]?.number ?? 0
        return PageLogEntry(seq: seq, time: isoFormatter.string(from: Date(timeIntervalSince1970: millis / 1000)), kind: kind, level: level,
                            text: clip(text, maxText), source: raw["source"]?.string, stack: raw["stack"]?.string.map { clip($0, maxStack) },
                            method: raw["method"]?.string, url: raw["url"]?.string, status: count(raw["status"]).flatMap { $0 > 0 ? $0 : nil },
                            resource: raw["resource"]?.string)
    }

    /// Web vitals as the page measured them, in milliseconds rounded to 0.1 (CLS unitless, to
    /// 0.001): a metric WebKit doesn't measure is null and named in `unsupported`, one not
    /// measured yet (no paint, no load event) is null too; never a zero standing in for either.
    static func vitals(_ raw: JSONValue?) -> JSONValue {
        func rounded(_ key: String, _ places: Double) -> JSONValue {
            guard let value = raw?[key]?.number, value.isFinite, value >= 0 else { return .null }
            return .number((value * places).rounded() / places)
        }
        var fields: [String: JSONValue] = [:]
        for key in ["lcp", "fcp", "ttfb", "domContentLoaded", "load"] { fields[key] = rounded(key, 10) }
        fields["cls"] = rounded("cls", 1000)
        let tasks = raw?["longTasks"]
        if let number = count(tasks?["count"]), let total = tasks?["totalMs"]?.number, total.isFinite {
            fields["longTasks"] = .object(["count": .number(Double(number)), "totalMs": .number((total * 10).rounded() / 10)])
        } else {
            fields["longTasks"] = .null
        }
        fields["unsupported"] = .array((raw?["unsupported"]?.array ?? []).compactMap { $0.string.map(JSONValue.string) })
        return .object(fields)
    }

    /// A whole, non-negative number the page reported; nil for anything else (a value `Int(_:)`
    /// would trap on included: the page's world can reach what it reports).
    static func count(_ value: JSONValue?) -> Int? {
        guard let number = value?.number, number.isFinite, number >= 0, number < 1e15 else { return nil }
        return Int(number)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// The entry for a page whose own document came back with an HTTP error status.
    public static func documentFailure(url: String, status: Int, at date: Date = Date()) -> PageLogEntry {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status)
        return PageLogEntry(seq: 0, time: isoFormatter.string(from: date), kind: .request, level: "error",
                            text: "\(url) → \(status) \(reason)", url: url, status: status, resource: "document")
    }
}

/// What `object.get` says about a browser tile's page (`page`): whether anyone sees it now
/// (`visibility`), what its current document reported (`log`), and the log of the page Canvas
/// last released (`previous`), kept so a page released out of view doesn't take its errors
/// with it.
public struct PageReport: Equatable, Sendable {
    /// How WebKit runs the page now, so frame and timer numbers read from it mean what they say.
    public enum Visibility: String, Sendable {
        /// On screen in its tile: requestAnimationFrame at the display's rate.
        case visible
        /// In its tile where nobody can see it (out of view, window minimized, covered, in a
        /// background tab, app hidden): no requestAnimationFrame, timers throttled more the
        /// longer it stays hidden.
        case hidden
        /// Kept visible to WebKit for an agent while nobody sees it: rAF and timers run, at an
        /// irregular, lower rate than on screen.
        case driven
        /// No page in memory (released, or never shown): it loads from `props.url` when the tile
        /// comes into view or an agent drives or renders it.
        case released
    }

    /// The log of a page Canvas released, as it was then.
    public struct Released: Equatable, Sendable {
        public var log: PageLog
        public var at: Date

        public init(log: PageLog, at: Date) {
            self.log = log
            self.at = at
        }
    }

    public var visibility: Visibility
    /// The current document's log; nil while there is no page.
    public var log: PageLog?
    public var previous: Released?

    public init(visibility: Visibility, log: PageLog?, previous: Released? = nil) {
        self.visibility = visibility
        self.log = log
        self.previous = previous
    }

    /// The API's `page`: the current document's log after `since` (`PageLog.json`), `loaded`,
    /// and `visibility`. `previous` (with `releasedAt`) is the released page's log, returned
    /// until `since` names the current document (the caller has read past the release). While
    /// released, `cursor` is the released page's, so a cursor loop carries on across the
    /// release and the reload after it.
    public func json(since: PageLog.Cursor? = nil) -> JSONValue {
        var fields: [String: JSONValue] = log?.json(since: since).object ?? ["loaded": .bool(false)]
        fields["visibility"] = .string(visibility.rawValue)
        if let previous, since.map({ $0.document != log?.document }) ?? true {
            let after = since.flatMap { $0.document == previous.log.document ? $0 : nil }
            var old = previous.log.json(since: after).object ?? [:]
            old["loaded"] = nil
            old["releasedAt"] = .string(PageLog.isoFormatter.string(from: previous.at))
            fields["previous"] = .object(old)
            if log == nil { fields["cursor"] = .string(previous.log.cursor) }
        }
        return .object(fields)
    }
}

/// Where a page's code is in the repo: a page log `source` or stack frame (`url:line:column`)
/// read back to the file the page loaded, so the error list opens it as a code tile.
public enum PageSource {
    public struct Location: Equatable, Sendable {
        public var url: URL
        public var line: Int
        public var column: Int?
    }

    /// The URL and line of a `source` (`http://localhost:8000/game.js:238:19`) or a WebKit
    /// stack frame (`update@http://…/game.js:238:19`, `global code@…`, a bare URL); Chrome's
    /// `at update (…:238:19)` reads too. Nil without a URL and line.
    public static func location(_ text: String) -> Location? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") { rest = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)] }
        if let at = rest.range(of: "@", options: .backwards), !rest[..<at.lowerBound].contains("/") { rest = rest[at.upperBound...] }
        guard let match = rest.wholeMatch(of: /(.+?):(\d+)(?::(\d+))?/), let line = Int(match.output.2), line > 0,
              let url = URL(string: String(match.output.1)), url.scheme != nil else { return nil }
        return Location(url: url, line: line, column: match.output.3.flatMap { Int($0) })
    }

    /// The existing file under the board root a page URL was served from: a `file:` URL's own
    /// path; a web URL's path (query dropped; a directory's `index.html`; Vite's `/@fs/<absolute>`)
    /// resolved like a terminal's ⌘-click reference (`TerminalReferences.resolve`): against
    /// the board root, then by trailing path among its `listed` files (`/static/game.js` →
    /// `public/static/game.js`). Only files inside `root`; nil when nothing resolves.
    public static func file(for url: URL, root: String, isFile: (String) -> Bool = TerminalReferences.isFile,
                            listed: FileIndex? = nil) -> String? {
        func real(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
        let base = real(root)
        func inside(_ path: String) -> String? {
            let standard = URL(fileURLWithPath: path).standardizedFileURL.path
            return real(standard).hasPrefix(base + "/") && isFile(standard) ? standard : nil
        }
        if url.isFileURL { return inside(url.path) }
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        var path = url.path(percentEncoded: false)
        if path.hasPrefix("/@fs/") { return inside(String(path.dropFirst(4))) }
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        let relative = String(path.drop { $0 == "/" })
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { return nil }
        return TerminalReferences.resolve(relative, directories: [root], home: NSHomeDirectory(), isFile: isFile,
                                          listed: listed.map { (root: root, files: $0) }, near: root).flatMap(inside)
    }
}

/// The page-side recorder for `PageLog`: a script injected at document start into the page's
/// own world (main frame), so it sees the page's console, errors and requests from the first
/// line of the page on. It keeps bounded buffers and reports nothing but a changed error count
/// (`messageName`, coalesced); everything else is read on demand (`readScript`).
///
/// It also starts omp's own capture globals in the shapes omp's cmux backend installs after
/// load (`__ompConsoleCapture`, `__ompCmuxResponses`): omp skips installing them when they
/// exist, so its `console()`, `errors()`, `requests()` and `waitForResponse()` cover page load.
public enum PageCapture {
    /// The message handler (page world) that hears the page's error count.
    public static let messageName = "canvasPageLog"
    /// The script's name in stack traces and the Web Inspector.
    public static let scriptName = "canvas-page-log.js"
    /// A stack frame of this script (WebKit shows injected scripts as `user-script:<n>`).
    public static func isOwnFrame(_ frame: String) -> Bool {
        frame.contains(scriptName) || frame.hasPrefix("user-script:") || frame.contains("@user-script:")
    }

    /// Returns the `PageLog` JSON as a string (evaluate in the page world).
    public static let readScript = "return globalThis.__canvasPageLog ? globalThis.__canvasPageLog.read() : null"

    public static let source = #"""
    (() => {
      if (Object.prototype.hasOwnProperty.call(globalThis, '__canvasPageLog')) return;
      const MAX_PROBLEMS = 200, MAX_OTHER = 200, MAX_TEXT = 1000, MAX_STACK = 4000;
      const OMP_ENTRIES = 500, OMP_RECORDS = 200, BODY_MAX = 65536;
      // This script's own frames (JavaScriptCore honors its sourceURL; WebKit's user scripts show as `user-script:<n>`).
      const marker = 'canvas-page-log.js';
      const handlers = globalThis.webkit && globalThis.webkit.messageHandlers;
      const handler = handlers && handlers.canvasPageLog;
      const post = (message) => { try { if (handler) handler.postMessage(message); } catch {} };
      const later = typeof globalThis.setTimeout === 'function' ? globalThis.setTimeout.bind(globalThis) : null;
      const listen = typeof globalThis.addEventListener === 'function' ? globalThis.addEventListener.bind(globalThis) : null;
      const ErrorEventType = typeof ErrorEvent === 'function' ? ErrorEvent : null;
      const ElementType = typeof Element === 'function' ? Element : null;
      const hasPerformance = typeof performance === 'object' && performance !== null;
      const now = () => Date.now();
      const clip = (text, limit) => text.length > limit ? text.slice(0, limit - 1) + '…' : text;
      const define = (name, value, writable) => Object.defineProperty(globalThis, name, { value, configurable: true, writable, enumerable: false });
      const documentId = String(Math.round(hasPerformance && performance.timeOrigin || now()));

      // MARK: Canvas's log: errors and warnings in one ring, everything else in another.
      const log = { problems: [], other: [], nextSeq: 1, dropped: 0, errors: 0, warnings: 0 };
      let announcing = false;
      const announce = () => {
        if (announcing) return;
        announcing = true;
        const send = () => { announcing = false; post(log.errors); };
        if (later) later(send, 100); else send();
      };
      const push = (entry) => {
        entry.seq = log.nextSeq++;
        entry.time = now();
        const problem = entry.level === 'error' || entry.level === 'warn';
        const ring = problem ? log.problems : log.other;
        ring.push(entry);
        if (ring.length > (problem ? MAX_PROBLEMS : MAX_OTHER)) { ring.shift(); log.dropped++; }
        if (entry.level === 'error') { log.errors++; announce(); } else if (entry.level === 'warn') log.warnings++;
      };

      // MARK: omp's capture, in the shapes its cmux backend reads.
      const omp = { entries: [], nextSeq: 1, dropped: 0 };
      const responses = { nextId: 1, records: [] };
      if (!globalThis.__ompConsoleCapture) define('__ompConsoleCapture', omp, true);
      if (!globalThis.__ompCmuxResponses) Object.defineProperty(globalThis, '__ompCmuxResponses', { value: responses, configurable: true });
      const pushOmp = (entry) => {
        entry.seq = omp.nextSeq++;
        entry.ts = now();
        omp.entries.push(entry);
        while (omp.entries.length > OMP_ENTRIES) { omp.entries.shift(); omp.dropped++; }
      };
      const ompText = (value) => {
        try { return String(value); } catch {}
        try { const json = JSON.stringify(value); if (json !== undefined) return json; } catch {}
        try { return Object.prototype.toString.call(value); } catch { return '[unserializable]'; }
      };
      // Serialized only when omp reads it (JSON.stringify calls toJSON), as omp's `safe` does.
      const ompArg = (value) => value === null || typeof value !== 'object' ? value : { toJSON() {
        try { const json = JSON.stringify(value); return json && json.length > 8192 ? json.slice(0, 8192) + '…' : value; } catch { return ompText(value); }
      } };
      const remember = (record) => {
        record.id = responses.nextId++;
        responses.records.push(record);
        if (responses.records.length > OMP_RECORDS) responses.records.splice(0, responses.records.length - OMP_RECORDS);
      };
      // A request that got no response (a resource that failed to load, a fetch that never got
      // an answer) is a record too, status 0, so omp's `requests()` lists what the page log does.
      const rememberFailure = (method, resourceType, url, reason, started) => remember({ ts: started, method, resourceType, url,
        status: 0, statusText: reason, headers: {}, requestHeaders: {}, body: '', durationMs: Math.max(0, now() - started) });

      // MARK: Text
      const preview = (value, depth) => {
        try {
          if (typeof value === 'string') return depth ? JSON.stringify(clip(value, 60)) : value;
          if (typeof value === 'function') return depth ? 'ƒ' : `ƒ ${value.name || 'anonymous'}()`;
          if (value === null || typeof value !== 'object') return String(value);
          if (value instanceof Error || (typeof value.message === 'string' && typeof value.name === 'string' && 'stack' in value)) {
            return `${value.name}: ${depth ? clip(String(value.message), 60) : value.message}`;
          }
          if (depth) return Array.isArray(value) ? `Array(${value.length})` : '{…}';
          if (Array.isArray(value)) {
            const items = value.slice(0, 5).map((item) => preview(item, 1));
            if (value.length > 5) items.push('…');
            return `[${items.join(', ')}]`;
          }
          if (ElementType && value instanceof ElementType) return `<${value.tagName.toLowerCase()}${value.id ? '#' + value.id : ''}>`;
          const keys = Object.keys(value);
          const shown = keys.slice(0, 5).map((key) => `${key}: ${preview(value[key], 1)}`);
          if (keys.length > 5) shown.push('…');
          const type = value.constructor && value.constructor !== Object && value.constructor.name ? value.constructor.name + ' ' : '';
          return `${type}{${shown.join(', ')}}`;
        } catch { return '[unserializable]'; }
      };
      // console's substitutions: %s %d %i %f %o %O, %c (styles, dropped), %%.
      const format = (args) => {
        if (typeof args[0] !== 'string' || !args[0].includes('%')) return args.map((arg) => preview(arg, 0)).join(' ');
        const rest = args.slice(1);
        const text = args[0].replace(/%[sdifoOc%]/g, (spec) => {
          if (spec === '%%') return '%';
          if (!rest.length) return spec;
          const value = rest.shift();
          if (spec === '%c') return '';
          if (spec === '%d' || spec === '%i') return String(parseInt(value, 10));
          if (spec === '%f') return String(parseFloat(value));
          return preview(value, 0);
        });
        return [text, ...rest.map((arg) => preview(arg, 0))].join(' ');
      };
      // The first stack frame outside this script: `url:line:column`.
      const frameSource = (stack) => {
        if (typeof stack !== 'string') return undefined;
        for (const line of stack.split('\n')) {
          // WebKit names injected scripts' frames `user-script:<n>` (this one, and never the page's).
          if (!line || line.includes(marker) || /(^|@)user-script:/.test(line.trim())) continue;
          // WebKit: `name@url:line:column`; V8 style: `at name (url:line:column)`.
          let location = line.trim();
          const at = location.lastIndexOf('@');
          if (at >= 0) location = location.slice(at + 1);
          const inner = /\(([^()]*)\)$/.exec(location);
          if (inner) location = inner[1];
          const match = /^(?:at\s+)?(\S.*):(\d+):(\d+)$/.exec(location);
          if (match) return `${match[1]}:${match[2]}:${match[3]}`;
        }
        return undefined;
      };
      const absolute = (url) => {
        try { return typeof location === 'object' && location ? new URL(String(url), location.href).href : String(url); } catch { return String(url); }
      };
      const statusText = (status, text) => text ? `${status} ${text}` : String(status);

      // MARK: Console
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = typeof console === 'object' && console ? console[level] : undefined;
        if (typeof original !== 'function') continue;
        console[level] = function (...args) {
          try {
            const entry = { kind: 'console', level, text: clip(format(args), MAX_TEXT) };
            if (level === 'warn' || level === 'error') {
              const error = args.find((arg) => arg instanceof Error);
              const source = frameSource(new Error().stack);
              if (source) entry.source = source;
              if (error && typeof error.stack === 'string') entry.stack = clip(error.stack, MAX_STACK);
            }
            push(entry);
            pushOmp({ type: 'console', level, text: clip(args.map(ompText).join(' '), 16384), args: args.map(ompArg) });
          } catch {}
          return original.apply(this, args);
        };
      }

      // MARK: Uncaught errors, unhandled rejections, resources that failed to load
      if (listen) {
        listen('error', (event) => {
          try {
            const target = event.target;
            if (ErrorEventType && !(event instanceof ErrorEventType)) {
              if (!ElementType || !(target instanceof ElementType)) return;
              const url = target.currentSrc || target.src || target.href || '';
              if (!url) return;
              const tag = target.tagName.toLowerCase();
              push({ kind: 'request', level: 'error', text: `${tag} ${url} failed to load`, url, resource: tag });
              rememberFailure('GET', tag, url, 'failed to load', now());
              return;
            }
            const error = event.error;
            const text = event.message || preview(error, 0) || 'Uncaught error';
            const entry = { kind: 'exception', level: 'error', text: clip(text, MAX_TEXT) };
            if (event.filename) entry.source = `${event.filename}:${event.lineno}:${event.colno}`;
            if (error && typeof error.stack === 'string') entry.stack = clip(error.stack, MAX_STACK);
            push(entry);
            pushOmp({ type: 'pageerror', level: 'error', text: clip(String(event.message || error || 'Uncaught error'), 16384),
              location: event.filename ? `${event.filename}:${event.lineno}:${event.colno}` : undefined,
              stack: error && error.stack ? clip(String(error.stack), 32768) : undefined });
          } catch {}
        }, true);
        listen('unhandledrejection', (event) => {
          try {
            const reason = event.reason;
            const stack = reason && typeof reason.stack === 'string' ? reason.stack : undefined;
            const entry = { kind: 'exception', level: 'error', text: clip(`Unhandled Promise Rejection: ${preview(reason, 0)}`, MAX_TEXT) };
            const source = frameSource(stack);
            if (source) entry.source = source;
            if (stack) entry.stack = clip(stack, MAX_STACK);
            push(entry);
            pushOmp({ type: 'pageerror', level: 'error', text: clip(String(reason && reason.message || reason), 16384), stack: stack ? clip(stack, 32768) : undefined });
          } catch {}
        });
        // A page restored from the back/forward cache keeps its log; the tile hears its count again.
        listen('pageshow', (event) => { if (event.persisted) post(log.errors); });
      }

      // MARK: fetch and XMLHttpRequest
      const headersObject = (headers) => {
        const out = {};
        try { if (headers && typeof headers.forEach === 'function') headers.forEach((value, name) => { out[name] = value; }); } catch {}
        return out;
      };
      // Bodies omp may read (`waitForResponse`): text only, the first BODY_MAX characters, never a stream.
      const textual = (type) => !type || (/json|text|xml|javascript|graphql|urlencoded/i.test(type) && !/event-stream/i.test(type));
      const readBody = async (response) => {
        try {
          if (!textual(response.headers && typeof response.headers.get === 'function' ? response.headers.get('content-type') : '')) return '';
          const copy = response.clone();
          if (copy.body && typeof copy.body.getReader === 'function' && typeof TextDecoder === 'function') {
            const reader = copy.body.getReader();
            const decoder = new TextDecoder();
            let text = '';
            while (text.length < BODY_MAX) {
              const { done, value } = await reader.read();
              if (done) break;
              text += decoder.decode(value, { stream: true });
            }
            reader.cancel().catch(() => {});
            return text.slice(0, BODY_MAX);
          }
          return String(await copy.text()).slice(0, BODY_MAX);
        } catch { return ''; }
      };
      const originalFetch = globalThis.fetch;
      if (typeof originalFetch === 'function') {
        globalThis.fetch = function fetch(input, init) {
          const started = now();
          let method = 'GET', url = '', requestHeaders = {};
          try {
            method = String((init && init.method) || (input && typeof input === 'object' && input.method) || 'GET').toUpperCase();
            url = absolute(input && typeof input === 'object' && 'url' in input ? input.url : input);
            const given = (init && init.headers) || (input && typeof input === 'object' && input.headers);
            requestHeaders = given && typeof Headers === 'function' ? headersObject(new Headers(given)) : headersObject(given);
          } catch {}
          return originalFetch.apply(this, arguments).then((response) => {
            try {
              const at = response.url || url;
              if (response.status >= 400) {
                push({ kind: 'request', level: 'error', text: `${method} ${at} → ${statusText(response.status, response.statusText)}`, method, url: at, status: response.status, resource: 'fetch' });
              }
              readBody(response).then((body) => remember({ ts: started, method, resourceType: 'fetch', url: at, status: response.status,
                statusText: response.statusText, headers: headersObject(response.headers), requestHeaders, body, durationMs: Math.max(0, now() - started) }));
            } catch {}
            return response;
          }, (error) => {
            try {
              if (!error || error.name !== 'AbortError') {
                push({ kind: 'request', level: 'error', text: `${method} ${url} failed: ${error && error.message || error}`, method, url, resource: 'fetch' });
                rememberFailure(method, 'fetch', url, String(error && error.message || error), started);
              }
            } catch {}
            throw error;
          });
        };
      }
      const XHR = globalThis.XMLHttpRequest;
      if (typeof XHR === 'function' && XHR.prototype) {
        const proto = XHR.prototype, open = proto.open, send = proto.send, setRequestHeader = proto.setRequestHeader;
        const requests = new WeakMap();
        function aborted() { const request = requests.get(this); if (request) request.aborted = true; }
        function finished() {
          try {
            const request = requests.get(this);
            if (!request) return;
            const url = this.responseURL || request.url;
            const status = this.status;
            if (!request.aborted && status === 0) {
              push({ kind: 'request', level: 'error', text: `${request.method} ${url} failed`, method: request.method, url, resource: 'xhr' });
            } else if (status >= 400) {
              push({ kind: 'request', level: 'error', text: `${request.method} ${url} → ${statusText(status, this.statusText)}`, method: request.method, url, status, resource: 'xhr' });
            }
            const headers = {};
            for (const line of String(this.getAllResponseHeaders() || '').trim().split(/[\r\n]+/)) {
              const index = line.indexOf(':');
              if (index > 0) headers[line.slice(0, index).trim().toLowerCase()] = line.slice(index + 1).trim();
            }
            const body = this.responseType === '' || this.responseType === 'text' ? String(this.responseText || '').slice(0, BODY_MAX) : '';
            remember({ ts: request.started, method: request.method, resourceType: 'xhr', url, status, statusText: this.statusText,
              headers, requestHeaders: request.headers, body, durationMs: Math.max(0, now() - request.started) });
          } catch {}
        }
        if (typeof open === 'function' && typeof send === 'function') {
          proto.open = function (method, url) {
            try { requests.set(this, { method: String(method || 'GET').toUpperCase(), url: absolute(url), headers: {}, started: now(), watched: false }); } catch {}
            return open.apply(this, arguments);
          };
          proto.send = function () {
            try {
              const request = requests.get(this);
              if (request) {
                request.started = now();
                request.aborted = false;
                if (!request.watched) {
                  request.watched = true;
                  this.addEventListener('abort', aborted);
                  this.addEventListener('loadend', finished);
                }
              }
            } catch {}
            return send.apply(this, arguments);
          };
        }
        if (typeof setRequestHeader === 'function') {
          proto.setRequestHeader = function (name, value) {
            try { const request = requests.get(this); if (request) request.headers[String(name).toLowerCase()] = String(value); } catch {}
            return setRequestHeader.apply(this, arguments);
          };
        }
      }

      // MARK: Web vitals: observed from the start where WebKit has the entry type, else null.
      const vitals = { lcp: null, cls: null, longTasks: null };
      const unsupported = [];
      const entryTypes = typeof PerformanceObserver === 'function' && PerformanceObserver.supportedEntryTypes || [];
      const observe = (type, each) => {
        if (!entryTypes.includes(type)) return false;
        try {
          new PerformanceObserver((list) => { try { list.getEntries().forEach(each); } catch {} }).observe({ type, buffered: true });
          return true;
        } catch { return false; }
      };
      if (!observe('largest-contentful-paint', (entry) => { vitals.lcp = entry.renderTime || entry.loadTime || entry.startTime; })) unsupported.push('lcp');
      if (observe('layout-shift', (entry) => { if (!entry.hadRecentInput) vitals.cls = (vitals.cls || 0) + entry.value; })) vitals.cls = 0; else unsupported.push('cls');
      if (observe('longtask', (entry) => { vitals.longTasks.count++; vitals.longTasks.totalMs += entry.duration; })) vitals.longTasks = { count: 0, totalMs: 0 };
      else unsupported.push('longTasks');
      const readVitals = () => {
        const out = { lcp: vitals.lcp, cls: vitals.cls, longTasks: vitals.longTasks && { count: vitals.longTasks.count, totalMs: vitals.longTasks.totalMs },
          fcp: null, ttfb: null, domContentLoaded: null, load: null, unsupported };
        try {
          const navigation = hasPerformance && performance.getEntriesByType('navigation')[0];
          if (navigation) {
            if (navigation.responseStart > 0) out.ttfb = navigation.responseStart;
            if (navigation.domContentLoadedEventEnd > 0) out.domContentLoaded = navigation.domContentLoadedEventEnd;
            if (navigation.loadEventEnd > 0) out.load = navigation.loadEventEnd;
          }
          const paint = hasPerformance && performance.getEntriesByName('first-contentful-paint')[0];
          if (paint) out.fcp = paint.startTime;
        } catch {}
        return out;
      };

      Object.defineProperty(globalThis, '__canvasPageLog', { configurable: false, enumerable: false, writable: false, value: Object.freeze({
        read: () => JSON.stringify({
          document: documentId,
          url: typeof location === 'object' && location ? location.href : '',
          entries: log.problems.concat(log.other).sort((a, b) => a.seq - b.seq),
          dropped: log.dropped, errors: log.errors, warnings: log.warnings, vitals: readVitals(),
        }),
      }) });
      // A new document starts clean: the tile's count follows it.
      post(0);
    })();
    //# sourceURL=canvas-page-log.js
    """#
}
