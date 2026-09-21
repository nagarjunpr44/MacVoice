// Tool layer: the user's own Shortcuts (Shortcuts.app) as voice-callable tools. Same pattern as
// tabs and windows — code lists the options, Jev picks one, code runs it — but one level above the
// GUI: a shortcut is a named automation (Messages, Calendar, Music, HomeKit, scripts), so there is
// no button to find and no keystroke to guess. Build a tool in Shortcuts, and voice can call it.
// Privacy: shortcut NAMES go to TypeSafe with the rest of the state (redacted by clean()); nothing else.
import Foundation

private var shortcutCache: (names: [String], at: Date)?

/// `shortcuts list` takes ~20 ms warm, ~150 ms cold. Cached 30 s and read while you are still
/// speaking (prepareScreen runs at speech start), so it never sits on the hot path.
func userShortcuts() -> [String] {
  if let c = shortcutCache, Date().timeIntervalSince(c.at) < 30 { return c.names }
  let p = Process(), out = Pipe()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
  p.standardOutput = out; p.standardError = FileHandle.nullDevice
  guard (try? p.run()) != nil else { return [] }
  DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if p.isRunning { p.terminate() } }  // a hung daemon must not freeze the snapshot
  let raw = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  let names = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  shortcutCache = (Array(names.prefix(200)), Date())
  return shortcutCache!.names
}

/// Fire and forget: a shortcut can take minutes or ask for input, and the app must stay responsive.
func runShortcut(_ name: String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["run", name]
  p.standardInput = FileHandle.nullDevice
  p.terminationHandler = { print("  · shortcut \"\(name)\" finished (exit \($0.terminationStatus))") }
  do { try p.run() } catch { print("  ! could not run shortcut \"\(name)\": \(error.localizedDescription)") }
}

/// Word-overlap shortlist, like shortlistTabs/shortlistElements: past ~30 options the right answer's
/// probability thins out and gets rejected. Short lists are returned whole. Indices stay the originals.
func shortlistNames(_ names: [String], _ utterance: String, keep: Int = 24) -> [Int] {
  guard names.count > keep else { return Array(names.indices) }
  let stop: Set<String> = ["run", "the", "a", "an", "my", "please", "shortcut", "start", "do", "open", "to", "for"]
  let words = utterance.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stop.contains($0) && $0.count > 1 }
  let hits = names.indices.map { i in (i, words.reduce(0) { $0 + (names[i].lowercased().contains($1) ? $1.count : 0) }) }
    .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
  var out = hits.prefix(keep).map(\.0)
  for i in names.indices where out.count < keep && !out.contains(i) { out.append(i) }  // pad, so "none" stays a fair option
  return out
}
