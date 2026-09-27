import Foundation

/// A page a browser tile couldn't load (nothing listening on the port, no such host, timed out,
/// offline): what the tile says in place of a blank page, and when it tries again. A dev server
/// started in a terminal beside the tile comes up seconds after the tile first asks (every tile
/// reloads at launch while the server's terminal restarts its command), so a local address is
/// retried a few times with backoff; a remote one waits for Reload.
public struct BrowserLoadFailure: Equatable, Sendable {
    public let url: URL
    /// What went wrong, in a few lowercase words ("connection refused").
    public let reason: String
    /// Failed loads of this address in a row, this one included (1 for the first).
    public let attempt: Int
    let retries: Bool

    /// Waits before each automatic retry of a local address, in order: about half a minute in all.
    public static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 15]

    /// Nil for errors that aren't a failed page: a cancelled or superseded navigation, a
    /// response the page handed to a download, a policy decision.
    public init?(url: URL, domain: String, code: Int, description: String, attempt: Int) {
        let reason: String
        var transient = false
        switch (domain, code) {
        case (NSURLErrorDomain, NSURLErrorCancelled): return nil
        // WebKit: "frame load interrupted" (a download or a policy change), plug-in handled.
        case ("WebKitErrorDomain", 102), ("WebKitErrorDomain", 203), ("WebKitErrorDomain", 204): return nil
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            reason = "connection refused"
            transient = true
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            reason = "connection lost"
            transient = true
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            reason = "timed out"
            transient = true
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            reason = "server not found"
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            reason = "offline"
        case (NSURLErrorDomain, NSURLErrorFileDoesNotExist):
            reason = "file not found"
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed), (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate), (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            reason = "secure connection failed"
        default:
            let text = description.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
            reason = text.isEmpty ? "error \(code)" : text.prefix(1).lowercased() + text.dropFirst()
        }
        self.url = url
        self.reason = reason
        self.attempt = attempt
        retries = transient && Self.isLocal(url)
    }

    /// "localhost:5391", "example.com", or the file's name.
    public var place: String {
        if url.isFileURL { return url.lastPathComponent }
        guard let host = url.host else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// The tile's headline: "Can't reach localhost:5391".
    public var headline: String { url.isFileURL ? "Can't open \(place)" : "Can't reach \(place)" }

    /// Seconds until the tile tries again by itself; nil when it won't (a remote address, an
    /// error retrying can't fix, or the retries are spent).
    public var retryDelay: TimeInterval? {
        guard retries, attempt >= 1, attempt <= Self.retryDelays.count else { return nil }
        return Self.retryDelays[attempt - 1]
    }

    /// The line under the headline: the reason, and the retry when one is due.
    public var detail: String {
        guard let delay = retryDelay else { return reason.prefix(1).uppercased() + reason.dropFirst() }
        return "\(reason.prefix(1).uppercased() + reason.dropFirst()) · trying again in \(Int(delay)) s"
    }

    /// For agents (a render's reason): "can't reach localhost:5391 (connection refused)".
    public var summary: String { "\(headline.prefix(1).lowercased() + headline.dropFirst()) (\(reason))" }

    /// A dev server on this machine: localhost and its subdomains, loopback and unspecified
    /// addresses, `.local` names.
    public static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasPrefix("127.") || host == "0.0.0.0" || host == "::1" || host == "[::1]"
    }
}
