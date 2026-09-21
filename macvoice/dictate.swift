// Dictation mode: while it is on, every utterance is typed verbatim. No Jev call and no is_command
// gate, because dictated prose is exactly what that gate exists to reject as conversation. Nothing
// leaves the Mac either: speech is recognised on-device and this path never talks to TypeSafe.
// Globals live here, not in main.swift, so they initialise before first use (see parse.swift).
import AppKit

var dictating = false
private var dictLast = Date()
private let dictIdle: TimeInterval = 45   // ponytail: fixed; a forgotten mode must not type your next chat message

private func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .caseInsensitive) }
private let startRe = rx("^(?:(?:start|begin|enter|turn on)\\s+)?dictat(?:e|ing|ion)(?:\\s+mode)?$|^start typing$")
private let stopRe = rx("\\b(?:(?:stop|end|finish|exit|done|turn off)\\s+dictati(?:ng|on)|dictation off)\\W*$")

/// Whole-utterance match only: "dictate hello" still types "hello" once, through the type_text intent.
func wantsDictation(_ text: String) -> Bool {
  let t = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
  return startRe.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
}

func startDictation() {
  dictating = true; dictLast = Date(); armIdle()
  listener?.refresh()   // the recogniser only takes punctuation at creation, so open a fresh request
  print("  ✎ dictating: what you say is typed as-is. \"stop dictating\" or ⌘M ends it")
  ui(.listening("dictating…")); beep("Pop")
}

func stopDictation(_ why: String) {
  guard dictating else { return }
  dictating = false
  listener?.refresh()
  print("  ✎ \(why)"); ui(.ok(why))
}

private func armIdle() {
  DispatchQueue.main.asyncAfter(deadline: .now() + dictIdle) {
    if dictating, Date().timeIntervalSince(dictLast) >= dictIdle - 0.5 { stopDictation("dictation timed out") }
  }
}

/// Types one utterance. "…the end, stop dictating" types "…the end" and then stops.
func dictate(_ heard: String) {
  var text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
  var stop = false
  if let m = stopRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) {
    text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces); stop = true
  }
  if !text.isEmpty {
    guard let front = NSWorkspace.shared.frontmostApplication, !isDenied(front.bundleIdentifier ?? "") else {
      stopDictation("dictation off: not typing into a protected app"); beep("Basso"); return
    }
    let low = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    print("  ✎ \(live ? "" : "DRY-RUN: would type ")\"\(text)\" → \(front.localizedName ?? "?")")
    if live && !demo {
      if low == "new line" { pressKey("enter") }
      else if low == "new paragraph" { pressKey("enter"); pressKey("enter") }
      else { typeText(text + " ") }
    }
  }
  if stop { stopDictation("dictation off"); return }
  dictLast = Date(); armIdle()
  ui(.listening("dictating…"))
}
