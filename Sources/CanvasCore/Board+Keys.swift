import Foundation

/// `props.key`: a name a script gives an object (a region per ticket, "REL-12389") to find it
/// again without keeping ids (`object.find`, `object.upsert`). Any type may have one; no two
/// objects on a board share one.
extension Board {
    /// An object's key: its `props.key` when that is a non-empty string.
    public static func key(_ props: JSONValue) -> String? {
        guard let key = props["key"]?.string, !key.isEmpty else { return nil }
        return key
    }

    /// Throws unless `props` may give object `id` (nil: one about to be created) its `key`: a
    /// non-empty string (or null, which removes it) that no other object on the board holds.
    public func checkKey(_ props: JSONValue?, for id: ObjectID?) throws {
        guard let value = props?["key"], value != .null else { return }
        guard let key = value.string, !key.isEmpty else { throw BoardError.invalidParams("props.key must be a non-empty string") }
        guard let holder = keyHolders[key]?.filter({ $0 != id }).min(), let object = objects[holder] else { return }
        throw BoardError.conflict("key \"\(key)\" is held by \(holder) (\(ActivityLog.describe(object)))")
    }

    /// The object holding `key`, nil when none does; a conflict when two do (a board file
    /// edited by hand), naming both.
    public func holder(ofKey key: String) throws -> CanvasObject? {
        guard let holders = keyHolders[key], let first = holders.min() else { return nil }
        guard holders.count == 1 else { throw BoardError.conflict("key \"\(key)\" is held by \(holders.sorted().joined(separator: ", "))") }
        return objects[first]
    }

    /// Every object whose key starts with `prefix`, in key order.
    public func objects(keyPrefix prefix: String) -> [CanvasObject] {
        keyHolders.filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.key < $1.key }
            .flatMap { $0.value.sorted().compactMap { objects[$0] } }
    }
}
