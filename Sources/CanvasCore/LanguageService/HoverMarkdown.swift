import Foundation

/// Splits hover markdown into the blocks a hover popover styles differently. Servers send small
/// documents: signatures in fences, prose with inline markup, headings, and `---` rules.
public enum HoverMarkdown {
    public enum Block: Equatable, Sendable {
        case code(language: String?, text: String)
        case heading(String)
        /// Paragraph text with inline markup left in place (rendered by the UI).
        case prose(String)
        case rule
    }

    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [Substring] = []
        var fence: (marker: Substring, language: String?, lines: [Substring])?

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.prose(text)) }
            prose = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if var open = fence {
                if trimmed.hasPrefix(open.marker), trimmed.drop(while: { $0 == open.marker.first }).allSatisfy(\.isWhitespace) {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    open.lines.append(line)
                    fence = open
                }
            } else if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                flushProse()
                let info = trimmed.drop { $0 == marker.first }.trimmingCharacters(in: .whitespaces)
                fence = (trimmed.prefix(while: { $0 == marker.first }), info.isEmpty ? nil : info, [])
            } else if trimmed.first == "#", let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }) {
                flushProse()
                blocks.append(.heading(trimmed[space...].trimmingCharacters(in: .whitespaces)))
            } else if ["---", "***", "___"].contains(trimmed.trimmingCharacters(in: .whitespaces)) {
                flushProse()
                blocks.append(.rule)
            } else if trimmed.isEmpty {
                flushProse()
            } else {
                prose.append(line)
            }
        }
        // An unterminated fence still shows its code.
        if let open = fence { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
        flushProse()
        return blocks
    }
}
