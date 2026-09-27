import Foundation

/// A changes tile's Revert and Stage (docs/contracts.md, Changes tiles): one unified patch
/// applied with `git apply` to the working tree or the index. Applying the same patch the other
/// way round is the undo, so every action is exactly reversible while the lines it touched are
/// as it left them; a patch that no longer applies is refused, never forced.
public struct ReviewPatch: Equatable, Sendable {
    public enum Target: String, Sendable { case worktree, index }

    /// The repository's top level; git runs there and the patch names paths relative to it.
    public var repository: URL
    public var text: String
    public var target: Target
    /// Applied reversed (`git apply -R`): a revert applies the base → working tree patch reversed.
    public var reverse: Bool

    public init(repository: URL, text: String, target: Target, reverse: Bool) {
        self.repository = repository
        self.text = text
        self.target = target
        self.reverse = reverse
    }

    /// The same change undone.
    public var inverse: ReviewPatch {
        var patch = self
        patch.reverse.toggle()
        return patch
    }

    public var arguments: [String] {
        ["apply", "--whitespace=nowarn"] + (target == .index ? ["--cached"] : []) + (reverse ? ["-R"] : []) + ["-"]
    }

    /// Changed lines a patch keeps when only part of a hunk is picked: removed lines by their
    /// old-side number, added lines by their new-side number.
    public struct LinePick: Equatable, Sendable {
        public var removed: Set<Int>
        public var added: Set<Int>

        public init(removed: Set<Int>, added: Set<Int>) {
            self.removed = removed
            self.added = added
        }
    }

    /// A unified patch turning `old` into `new` over `mappings` for `path` (repository-relative),
    /// with `context` lines around each hunk. `old` nil creates the file, `new` nil deletes it;
    /// modes only appear in those headers. Lines keep their own endings (CRLF too), and a last
    /// line without one gets git's `\ No newline at end of file`.
    ///
    /// `pick`: only those changed lines. Within each change (its removed lines, then its added
    /// ones) the n-th removed and n-th added line are a pair and stay together, so picking one
    /// replacement of several keeps the others in place. Applied forward (`reverse` false: the
    /// target holds `old`), an unpicked removed line becomes context and an unpicked added line
    /// is dropped; applied reversed (the target holds `new`), an unpicked added line becomes
    /// context and an unpicked removed line is dropped. Either way unpicked lines stay as the
    /// target has them, as `git add -p` edits a hunk. Headers are recounted; a hunk left with no
    /// change is dropped, and a patch left with none is empty.
    public static func text(path: String, old: SideText?, new: SideText?, oldMode: String? = nil, newMode: String? = nil,
                            mappings: [LineRangeMapping], context: Int = 3, pick: LinePick? = nil, reverse: Bool = false) -> String {
        let a = quoted("a/" + path), b = quoted("b/" + path)
        var out = "diff --git \(a) \(b)\n"
        if old == nil, pick == nil || !reverse {
            out += "new file mode \(newMode ?? "100644")\n--- /dev/null\n+++ \(b)\n"
        } else if new == nil, pick == nil || reverse {
            out += "deleted file mode \(oldMode ?? "100644")\n--- \(a)\n+++ /dev/null\n"
        } else {
            out += "--- \(a)\n+++ \(b)\n"
        }
        let oldText = old ?? SideText(""), newText = new ?? SideText("")
        guard let pick else {
            for hunk in UnifiedDiff.hunks(mappings, context: context) {
                let change = ChangeHunk(mappings: hunk.mappings, old: oldText, new: newText, context: context)
                out += change.header + "\n"
                for line in change.lines {
                    switch line.kind {
                    case .context: out += " " + raw(newText, line.new!)
                    case .removed: out += "-" + raw(oldText, line.old!)
                    case .added: out += "+" + raw(newText, line.new!)
                    }
                }
            }
            return out
        }
        // What applying the earlier hunks adds to the side the target doesn't hold.
        var delta = 0
        var any = false
        for hunk in UnifiedDiff.hunks(mappings, context: context) {
            let change = ChangeHunk(mappings: hunk.mappings, old: oldText, new: newText, context: context)
            var body = ""
            var kept = (context: 0, removed: 0, added: 0)
            let lines = change.lines
            var index = 0
            while index < lines.count {
                if lines[index].kind == .context {
                    body += " " + raw(newText, lines[index].new!)
                    kept.context += 1
                    index += 1
                    continue
                }
                var removed: [Int] = [], added: [Int] = []
                while index < lines.count, lines[index].kind == .removed {
                    removed.append(lines[index].old!)
                    index += 1
                }
                while index < lines.count, lines[index].kind == .added {
                    added.append(lines[index].new!)
                    index += 1
                }
                for pair in 0..<max(removed.count, added.count) {
                    if pair < removed.count {
                        if pick.removed.contains(removed[pair]) {
                            body += "-" + raw(oldText, removed[pair])
                            kept.removed += 1
                        } else if !reverse {
                            body += " " + raw(oldText, removed[pair])
                            kept.context += 1
                        }
                    }
                    if pair < added.count {
                        if pick.added.contains(added[pair]) {
                            body += "+" + raw(newText, added[pair])
                            kept.added += 1
                        } else if reverse {
                            body += " " + raw(newText, added[pair])
                            kept.context += 1
                        }
                    }
                }
            }
            guard kept.removed + kept.added > 0 else { continue }
            any = true
            let oldCount = kept.context + kept.removed, newCount = kept.context + kept.added
            let oldStart: Int, newStart: Int
            if reverse {
                newStart = change.newStart
                let first = (change.newCount == 0 ? change.newStart + 1 : change.newStart) - delta
                oldStart = oldCount == 0 ? first - 1 : first
            } else {
                oldStart = change.oldStart
                let first = (change.oldCount == 0 ? change.oldStart + 1 : change.oldStart) + delta
                newStart = newCount == 0 ? first - 1 : first
            }
            delta += kept.added - kept.removed
            func span(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
            out += "@@ -\(span(oldStart, oldCount)) +\(span(newStart, newCount)) @@\n" + body
        }
        return any ? out : ""
    }

    /// A line with its own line break, or with git's no-newline marker when it has none.
    static func raw(_ text: SideText, _ line: Int) -> String {
        let start = text.lineStarts[line - 1]
        let end = line < text.lineCount ? text.lineStarts[line] : text.utf16Count
        let slice = (text.text as NSString).substring(with: NSRange(location: start, length: end - start))
        // By UTF-16 unit: "\r\n" is one Character, which never `hasSuffix("\n")`.
        return slice.utf16.last == 0x0A ? slice : slice + "\n\\ No newline at end of file\n"
    }

    /// A patch header path, C-quoted as git writes names with quotes, backslashes, or control
    /// characters.
    static func quoted(_ path: String) -> String {
        guard path.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) else { return path }
        var out = "\""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\%03o", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Actions

    /// Revert: the hunks' changes discarded from the working tree (the base's lines put back),
    /// as the base → working tree patch of `file` applied reversed. All hunks of a created or
    /// deleted file are the file (deleted again, or brought back). A renamed file keeps its name.
    /// `lines`: only those rows (indices into the one hunk's `lines`) of the hunk.
    public static func revert(_ hunks: [ChangeHunk], of file: ChangedFile, in repository: URL, lines: Set<Int>? = nil) throws -> ReviewPatch {
        try checkPath(file.path)
        let mappings = file.status == .added || file.status == .deleted ? file.mappings : hunks.flatMap(\.mappings)
        guard !mappings.isEmpty || file.status == .added || file.status == .deleted else { throw ChangesFailure("nothing to revert in \(file.boardPath)") }
        let pick = try lines.map { try Self.pick($0, of: hunks) }
        let text = text(path: file.path, old: file.status == .added ? nil : file.old, new: file.status == .deleted ? nil : file.new,
                        oldMode: file.oldMode, newMode: file.newMode, mappings: mappings, pick: pick, reverse: true)
        guard !text.isEmpty else { throw ChangesFailure("no changed line selected") }
        return ReviewPatch(repository: repository, text: text, target: .worktree, reverse: true)
    }

    /// The changed lines among `rows` (indices into the one hunk's `lines`), by side.
    static func pick(_ rows: Set<Int>, of hunks: [ChangeHunk]) throws -> LinePick {
        guard hunks.count == 1, let hunk = hunks.first else { throw ChangesFailure("lines are picked within one hunk") }
        var pick = LinePick(removed: [], added: [])
        for index in rows where hunk.lines.indices.contains(index) {
            let line = hunk.lines[index]
            switch line.kind {
            case .removed: pick.removed.insert(line.old!)
            case .added: pick.added.insert(line.new!)
            case .context: break
            }
        }
        guard !pick.removed.isEmpty || !pick.added.isEmpty else { throw ChangesFailure("no changed line selected") }
        return pick
    }

    /// Stage: the index takes the working tree's lines where `file` changes over `hunks` (nil:
    /// the whole file), whatever base the tile compares with. Built from the index and the
    /// working tree as they are now: an untracked file is added whole, a deleted one removed.
    /// `lines`: only those rows (indices into the one hunk's `lines`): added lines by their
    /// working-tree line, removed ones by the index line with the same text in the change there.
    public static func stage(_ hunks: [ChangeHunk]?, of file: ChangedFile, in repository: URL, lines: Set<Int>? = nil, runner: GitRunner = .shared) async throws -> ReviewPatch {
        try checkPath(file.path)
        let picked = try lines.map { try Self.pick($0, of: hunks ?? []) }
        // Index lines holding the picked base lines' text among `candidates`.
        func indexLines(_ candidates: [Int], in index: SideText, for base: [Int]) -> Set<Int> {
            var found: Set<Int> = []
            for line in base.sorted() where line >= 1 && line <= file.old.lineCount {
                let text = file.old.line(line)
                if let match = candidates.first(where: { !found.contains($0) && $0 >= 1 && $0 <= index.lineCount && index.line($0) == text }) { found.insert(match) }
            }
            return found
        }
        let url = repository.appendingPathComponent(file.path)
        var indexMode: String?
        if let listing = try? await runner.run(["--literal-pathspecs", "ls-files", "-s", "-z", "--", file.path], in: repository),
           let record = listing.split(separator: 0).first {
            indexMode = String(decoding: record, as: UTF8.self).split(separator: " ").first.map(String.init)
        }
        let index: SideText?
        if indexMode != nil {
            guard let data = try? await runner.run(["cat-file", "blob", ":\(file.path)"], in: repository, maxOutput: GitDiffEngine.maxFileSize) else {
                throw ChangesFailure("can't read \(file.boardPath) from the index")
            }
            index = await offPool { SideText(String(decoding: data, as: UTF8.self)) }
        } else {
            index = nil
        }
        let worktree = await offPool { (try? Data(contentsOf: url)).map { SideText(String(decoding: $0, as: UTF8.self)) } }
        let text: String
        switch (index, worktree) {
        case (nil, nil):
            throw ChangesFailure("\(file.boardPath) is neither in the index nor on disk")
        case (nil, let worktree?):
            text = Self.text(path: file.path, old: nil, new: worktree, newMode: ChangeSet.mode(of: url), mappings: worktree.lineCount == 0 ? [] : [LineRangeMapping(original: 1..<1, modified: 1..<(worktree.lineCount + 1))],
                             pick: picked.map { LinePick(removed: [], added: $0.added) })
        case (let index?, nil):
            text = Self.text(path: file.path, old: index, new: nil, oldMode: indexMode, mappings: index.lineCount == 0 ? [] : [LineRangeMapping(original: 1..<(index.lineCount + 1), modified: 1..<1)],
                             pick: picked.map { LinePick(removed: indexLines(Array(1...max(1, index.lineCount)), in: index, for: Array($0.removed)), added: []) })
        case (let index?, let worktree?):
            let args = ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--diff-algorithm=histogram",
                        "-U0", "--inter-hunk-context=0", "--src-prefix=a/", "--dst-prefix=b/", "--", file.path]
            let patch = try await runner.run(args, in: repository, maxOutput: 3 * GitDiffEngine.maxFileSize)
            let parsed = await offPool { UnifiedDiff.parse(patch) }
            // git read the file after we did: a patch that doesn't describe our text is stale.
            guard await offPool({ UnifiedDiff.reconstructOld(new: worktree, parsed: parsed) }) == index else {
                throw ChangesFailure("\(file.boardPath) changed while staging; try again")
            }
            let ranges = hunks?.flatMap { $0.mappings.map(\.modified) }
            let selected = ranges.map { ranges in parsed.mappings.filter { change in ranges.contains { ChangeHunk.touches($0, change.modified) } } } ?? parsed.mappings
            guard !selected.isEmpty else { throw ChangesFailure("already staged") }
            var pick: LinePick?
            if let picked, let hunk = hunks?.first {
                var removed: Set<Int> = []
                for mapping in hunk.mappings {
                    let base = mapping.original.filter(picked.removed.contains)
                    guard !base.isEmpty else { continue }
                    let candidates = selected.filter { ChangeHunk.touches($0.modified, mapping.modified) }.flatMap { Array($0.original) }
                    removed.formUnion(indexLines(candidates, in: index, for: base))
                }
                pick = LinePick(removed: removed, added: picked.added)
            }
            text = Self.text(path: file.path, old: index, new: worktree, mappings: selected, pick: pick)
        }
        guard !text.isEmpty else { throw ChangesFailure("already staged") }
        return ReviewPatch(repository: repository, text: text, target: .index, reverse: false)
    }

    /// Patch lines a `props.reviewed` entry carries at most; `truncated` says there were more.
    public static let maxEntryLines = 200

    /// The `props.reviewed` entry for an applied action on `file` (`hunk` nil: all of it;
    /// `lines`: rows of the hunk picked): what, where (`hunk`: the hunk's stable id, `label`),
    /// how much, and the patch it applied (`patch`, as `git apply` took it; a revert's is the
    /// base → working tree diff applied reversed), capped.
    public static func entry(_ action: String, file: ChangedFile, hunk: ChangeHunk?, lines: Set<Int>?, patch: ReviewPatch) -> JSONValue {
        var entry: [String: JSONValue] = ["action": .string(action), "path": .string(file.boardPath),
                                          "scope": .string(hunk == nil ? "file" : lines == nil ? "hunk" : "lines"), "status": .string(file.status.rawValue)]
        if let hunk {
            entry["hunk"] = .string(hunk.id)
            entry["header"] = .string(hunk.header)
            entry["label"] = .string(hunk.label)
            let rows = lines.map { picked in hunk.lines.indices.filter(picked.contains).map { hunk.lines[$0] } } ?? hunk.lines
            entry["added"] = .number(Double(rows.filter { $0.kind == .added }.count))
            entry["removed"] = .number(Double(rows.filter { $0.kind == .removed }.count))
        } else {
            entry["added"] = .number(Double(file.added))
            entry["removed"] = .number(Double(file.removed))
        }
        let patchLines = patch.text.split(separator: "\n", omittingEmptySubsequences: false)
        let body = patchLines.last == "" ? patchLines.dropLast() : patchLines[...]
        entry["patch"] = .string(body.prefix(maxEntryLines).joined(separator: "\n") + "\n")
        if body.count > maxEntryLines { entry["truncated"] = .bool(true) }
        if patch.reverse { entry["applied"] = .string("reversed") }
        return .object(entry)
    }

    /// Patches only ever name files inside their repository.
    static func checkPath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".git") else {
            throw ChangesFailure("refusing to patch \(path): outside the repository")
        }
    }
}

extension Notification.Name {
    /// Posted (object: the repository's top-level path) after a changes tile's patch applied,
    /// its undo and redo included: tiles showing that repository reload.
    public static let reviewPatchApplied = Notification.Name("canvas.reviewPatchApplied")
    /// Posted (object: the changes tile's id, userInfo `message`) when undoing or redoing a
    /// tile's action couldn't apply.
    public static let reviewPatchFailed = Notification.Name("canvas.reviewPatchFailed")
}

/// Applies review patches one at a time, in the order asked (an undo right after its action
/// waits for it), through `GitRunner`.
@MainActor
public final class ReviewGit {
    public static let shared = ReviewGit()

    private let runner: GitRunner
    private var tail: Task<Void, Never>?

    public init(runner: GitRunner = .shared) {
        self.runner = runner
    }

    /// Queues `patch` behind everything asked before it (at once, so an undo asked right after
    /// its action runs after it); the task answers why it didn't apply (the lines changed
    /// since, the index is locked), nil when it did.
    @discardableResult
    public func enqueue(_ patch: ReviewPatch) -> Task<ChangesFailure?, Never> {
        let previous = tail
        let runner = runner
        let work = Task<ChangesFailure?, Never> {
            await previous?.value
            let failure: ChangesFailure?
            do {
                _ = try await runner.run(patch.arguments, in: patch.repository, input: Data(patch.text.utf8))
                failure = nil
            } catch GitError.failed(_, let stderr) {
                failure = ChangesFailure(Self.reason(stderr))
            } catch {
                failure = ChangesFailure("git apply failed: \(error)")
            }
            if failure == nil { NotificationCenter.default.post(name: .reviewPatchApplied, object: patch.repository.path) }
            return failure
        }
        tail = Task { _ = await work.value }
        return work
    }

    /// `enqueue`, throwing its refusal.
    public func apply(_ patch: ReviewPatch) async throws {
        if let failure = await enqueue(patch).value { throw failure }
    }

    /// Waits until every patch asked for so far has applied or failed.
    public func settled() async {
        await tail?.value
    }

    /// git's complaint, said for the user.
    static func reason(_ stderr: String) -> String {
        if stderr.contains("index.lock") { return "the index is locked by another git process; try again" }
        if stderr.contains("patch does not apply") || stderr.contains("does not match index") || stderr.contains("already exists") || stderr.contains("does not exist") {
            return "no longer applies: the lines changed since"
        }
        return stderr.split(separator: "\n").first.map(String.init) ?? "git apply failed"
    }
}

extension Board {
    /// A changes tile fitted to its diff (`size: "fit"`) grown to show it again once hunks were
    /// added (`ChangesTile`): the app's own write-back, credited to the system, and not an undo
    /// step, so ⌘Z keeps undoing what someone did.
    public func growFitted(_ id: ObjectID, frame: Frame) {
        guard !history.isOpen else { return }
        history.replaying = true
        defer { history.replaying = false }
        _ = try? update(id, frame: frame, actor: .system)
    }

    /// Log entries a changes tile keeps in `props.reviewed`, newest last.
    public static let reviewedLimit = 100

    /// A review action the tile already applied (`patch`), recorded as one undo step with an
    /// entry in the tile's `props.reviewed`: ⌘Z applies the patch the other way round (a revert
    /// comes back, a stage leaves the index) and drops the entry; redo applies it again. When
    /// the lines moved on meanwhile, the undo is refused and `.reviewPatchFailed` says so.
    public func recordReview(tile: ObjectID, entry: JSONValue, patch: ReviewPatch, git: ReviewGit = .shared) throws {
        let object = try object(tile)
        var reviewed = object.props["reviewed"]?.array ?? []
        reviewed.append(entry)
        if reviewed.count > Self.reviewedLimit { reviewed.removeFirst(reviewed.count - Self.reviewedLimit) }
        let what = [entry["action"]?.string, entry["path"]?.string, entry["header"]?.string].compactMap { $0 }.joined(separator: " ")
        transaction {
            _ = try? update(tile, props: .object(["reviewed": .array(reviewed)]))
            history.record(.effect(UndoEffect(undo: { Self.replay(patch.inverse, "undo", what, tile: tile, git: git) },
                                              redo: { Self.replay(patch, "redo", what, tile: tile, git: git) })))
        }
    }

    /// Undo or redo of a recorded review action: the patch applied in the background, a refusal
    /// reported to the tile.
    private static func replay(_ patch: ReviewPatch, _ verb: String, _ what: String, tile: ObjectID, git: ReviewGit) {
        let work = git.enqueue(patch)
        Task { @MainActor in
            guard let failure = await work.value else { return }
            NotificationCenter.default.post(name: .reviewPatchFailed, object: tile, userInfo: ["message": "Couldn't \(verb) \(what): \(failure.message)"])
        }
    }
}
