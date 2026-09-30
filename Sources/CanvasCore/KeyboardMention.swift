import Foundation

/// Edit › Mention (⇧⌘M): a mention staged from the keyboard, of what the user is on.
public enum KeyboardMention {
    /// What the command stages. `keyboardTile`: the tile that has the keyboard; `current` its
    /// answer for what the user is on in it (a changes tile's selected lines or current hunk, a
    /// code tile's selected text or range, a note's block, a page's selection, a terminal's
    /// selection or last command block), else, with the canvas's keyboard, the one selected
    /// tile's (only an explicit sub-selection: a hunk, selected text). Without a `current`: the
    /// keyboard tile itself; else the selection: one object (a drawing brings the sketch it is
    /// part of, as a Hyper-click does; a group its members, named by its title), several as one
    /// group in reading order. Nil: nothing to mention.
    @MainActor public static func target(keyboardTile: ObjectID?, selection: Set<ObjectID>, current: MentionTarget?, on board: Board) -> MentionTarget? {
        if let tile = keyboardTile, board.objects[tile] != nil { return current ?? .object(tile) }
        let selected = selection.compactMap { board.objects[$0] }
        if selected.count == 1, let only = selected.first {
            if let current { return current }
            if only.type == .shape || only.type == .arrow { return MentionContext.drawingTarget(only.id, selection: selection, on: board) }
            if only.type == .group, let group = GroupMention.target(only.id, on: board) { return group }
            return .object(only.id)
        }
        guard selected.count > 1 else { return nil }
        let ordered = selected.sorted { a, b in
            if a.frame.y != b.frame.y { return a.frame.y < b.frame.y }
            if a.frame.x != b.frame.x { return a.frame.x < b.frame.x }
            return a.id < b.id
        }
        return .group(objects: ordered.map(\.id), name: nil)
    }

    /// The lines Go to (⌘P) landed on in the code tile `object`, which it selects so ⇧⌘M
    /// mentions them (and ⌘C copies them), not the whole tile: a `path:line` or symbol row's
    /// `lines`, else, for a code tile's own row ("forecast.py · L7–9"), the range it showed.
    /// Nil for anything but a code tile, and for a file opened without lines.
    public static func goToLines(_ lines: LineRange?, landedOn object: CanvasObject?) -> LineRange? {
        guard let object, object.type == .code else { return nil }
        if let lines { return lines }
        guard let start = object.props["range"]?["start"]?.int else { return nil }
        return LineRange(start: start, end: max(start, object.props["range"]?["end"]?.int ?? start))
    }
}

extension ChangeSet {
    /// A mention of hunk lines in a changes tile: `lines` (row indices in the hunk; a selection,
    /// possibly with gaps) on the working-tree side when any of them is there, else on the old
    /// side; nil `lines`: the whole hunk. Also what the mention says about them
    /// (`mentionDetail`). Nil when the hunk or lines aren't in the listing.
    public func mention(file: Int, hunk: Int, lines: Set<Int>?) -> (path: String, lines: LineRange, side: DiffSide, detail: String?)? {
        guard files.indices.contains(file), files[file].hunks.indices.contains(hunk) else { return nil }
        let changed = files[file], target = changed.hunks[hunk]
        guard let lines else {
            let whole = target.mentionLines
            return (whole.side == .old ? changed.oldBoardPath ?? changed.boardPath : changed.boardPath, whole.lines, whole.side,
                    mentionDetail(file: file, hunk: hunk, lines: nil))
        }
        let located = lines.sorted().compactMap { location(file: file, hunk: hunk, line: $0) }
        let side: DiffSide = located.contains { $0.side == .new } ? .new : .old
        let onSide = located.filter { $0.side == side }
        guard let first = onSide.first, let low = lines.min(), let high = lines.max() else { return nil }
        let numbers = onSide.map(\.line)
        return (first.path, LineRange(start: numbers.min()!, end: numbers.max()!), side, mentionDetail(file: file, hunk: hunk, lines: low..<(high + 1)))
    }
}
