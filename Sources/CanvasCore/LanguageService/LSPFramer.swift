import Foundation

/// LSP base-protocol framing: `Content-Length: N` (plus optional headers), a blank line, then N
/// bytes of UTF-8 JSON. Pipe reads split and concatenate messages arbitrarily, so bytes are
/// buffered until a whole body is present.
public struct LSPFramer: Sendable {
    public enum FramingError: Error, Equatable {
        /// A header block without a usable Content-Length; the stream can't be resynchronized.
        case missingContentLength(String)
    }

    private static let separator = Data("\r\n\r\n".utf8)
    private var buffer = Data()

    public init() {}

    /// Appends a chunk and returns every body it completes, in order.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var bodies: [Data] = []
        var cursor = buffer.startIndex
        while let headerEnd = buffer[cursor...].firstRange(of: Self.separator) {
            let header = String(decoding: buffer[cursor..<headerEnd.lowerBound], as: UTF8.self)
            guard let length = Self.contentLength(header) else {
                buffer.removeAll()
                throw FramingError.missingContentLength(header)
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            bodies.append(Data(buffer[bodyStart..<bodyEnd]))
            cursor = bodyEnd
        }
        if cursor != buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<cursor) }
        return bodies
    }

    public static func frame(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    private static func contentLength(_ header: String) -> Int? {
        for line in header.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil }
        }
        return nil
    }
}
