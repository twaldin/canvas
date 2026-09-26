// Replays input into a Canvas instance launched with CANVAS_DEV_INPUT=1 (see docs/testing.md).
// Coordinates are window-content points with a top-left origin, matching `view.snapshot` pixels / 2.
//
//   dev-input <pid> click <x> <y> [--mods hyper|cmd|shift|opt|ctrl[+…]] [--clicks 2]
//   dev-input <pid> rightclick <x> <y>
//   dev-input <pid> drag <x> <y> <toX> <toY> [--mods …]
//   dev-input <pid> flags <x> <y> [--mods …]         hold modifiers with the pointer at x,y (hover); no --mods releases
//   dev-input <pid> text "<string>"                  insert text into the first responder
//   dev-input <pid> command <selector>               e.g. insertNewline: deleteBackward: cancelOperation:
//   dev-input <pid> shortcut <key> [--mods cmd]      key equivalent, e.g. shortcut z --mods cmd
//   dev-input <pid> scroll <x> <y> <dx> <dy>         pan by pixels
//   any kind: --repeat N [--interval ms]             a burst (default 8 ms apart); app.log reports the lag
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}
let mods = option("--mods")
let clicks = option("--clicks")
let repeatCount = option("--repeat")
let interval = option("--interval")
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: dev-input <pid> <kind> …  (see header of scripts/dev-input.swift)\n".utf8))
    exit(2)
}
var info: [String: String] = ["pid": args[0], "kind": args[1]]
let rest = Array(args.dropFirst(2))
switch args[1] {
case "click", "rightclick", "flags":
    guard rest.count >= 2 else { exit(2) }
    info["x"] = rest[0]; info["y"] = rest[1]
case "drag":
    guard rest.count >= 4 else { exit(2) }
    info["x"] = rest[0]; info["y"] = rest[1]; info["toX"] = rest[2]; info["toY"] = rest[3]
case "text":
    info["text"] = rest.joined(separator: " ")
case "command":
    info["selector"] = rest.first ?? ""
case "shortcut":
    info["key"] = rest.first ?? ""
case "scroll":
    guard rest.count >= 4 else { exit(2) }
    info["x"] = rest[0]; info["y"] = rest[1]; info["dx"] = rest[2]; info["dy"] = rest[3]
default:
    FileHandle.standardError.write(Data("unknown kind \(args[1])\n".utf8))
    exit(2)
}
if let mods { info["mods"] = mods }
if let clicks { info["clicks"] = clicks }
if let repeatCount { info["repeat"] = repeatCount }
if let interval { info["interval"] = interval }
DistributedNotificationCenter.default().postNotificationName(Notification.Name("canvas.dev.input"), object: nil, userInfo: info, deliverImmediately: true)
// Replayed events are queued; give the app a moment before the caller inspects state.
usleep(150_000)
