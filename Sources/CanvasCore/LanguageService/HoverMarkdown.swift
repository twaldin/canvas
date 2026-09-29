import Foundation

/// Hover markdown as the blocks a hover popover styles differently. Servers send small
/// documents: signatures in fences or indented code, prose with inline markup, headings, and
/// `---` rules. Headings and prose come with their inline markup resolved (`Span`): backslash
/// escapes and entities decoded as CommonMark does, while code keeps every character.
public enum HoverMarkdown {
    public enum Block: Equatable, Sendable {
        case code(language: String?, text: String)
        case heading([Span])
        case prose([Span])
        case rule
    }

    /// Text as it reads, with the inline styles it was marked up with.
    public struct Span: Equatable, Sendable {
        public var text: String
        public var code: Bool
        public var strong: Bool
        public var emphasis: Bool
        public var link: Bool

        public init(_ text: String, code: Bool = false, strong: Bool = false, emphasis: Bool = false, link: Bool = false) {
            self.text = text
            self.code = code
            self.strong = strong
            self.emphasis = emphasis
            self.link = link
        }
    }

    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [Substring] = []
        var fence: (marker: Substring, language: String?, lines: [Substring])?
        var indented: [Substring]?

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.prose(inline(text))) }
            prose = []
        }

        func flushIndented() {
            guard let lines = indented else { return }
            let text = lines.map { dropIndent($0) }.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { blocks.append(.code(language: nil, text: text)) }
            indented = nil
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
                continue
            }
            // An indented code block (four spaces or a tab) runs until a line that isn't; it
            // can't interrupt a paragraph, where the indentation is a continuation line's.
            if indented != nil, line.allSatisfy(\.isWhitespace) || isIndentedCode(line) {
                indented?.append(line)
                continue
            }
            flushIndented()
            let bare = trimmed.trimmingCharacters(in: .whitespaces)
            if prose.isEmpty, isIndentedCode(line), !line.allSatisfy(\.isWhitespace) {
                indented = [line]
            } else if !prose.isEmpty, !isIndentedCode(line), let underline = bare.first, underline == "=" || underline == "-", bare.allSatisfy({ $0 == underline }) {
                // A setext heading: the paragraph above it, underlined with `=` or `-`.
                blocks.append(.heading(inline(prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))))
                prose = []
            } else if let marker = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                flushProse()
                let info = trimmed.drop { $0 == marker.first }.trimmingCharacters(in: .whitespaces)
                fence = (trimmed.prefix(while: { $0 == marker.first }), info.isEmpty ? nil : info, [])
            } else if trimmed.first == "#", let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }) {
                flushProse()
                blocks.append(.heading(inline(trimmed[space...].trimmingCharacters(in: .whitespaces))))
            } else if ["---", "***", "___"].contains(bare) {
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
        flushIndented()
        flushProse()
        return blocks
    }

    /// A heading's or paragraph's inline markup (emphasis, code spans, links, escapes, entities)
    /// resolved by Foundation's CommonMark parser, line breaks and indentation kept as written.
    static func inline(_ text: String) -> [Span] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return [Span(text)] }
        return parsed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            return Span(String(parsed[run.range].characters), code: intent.contains(.code), strong: intent.contains(.stronglyEmphasized),
                        emphasis: intent.contains(.emphasized), link: run.link != nil)
        }
    }

    private static func isIndentedCode(_ line: Substring) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    private static func dropIndent(_ line: Substring) -> Substring {
        line.hasPrefix("\t") ? line.dropFirst() : line.dropFirst(min(4, line.prefix { $0 == " " }.count))
    }
}
