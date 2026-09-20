// Command text parsing. These live OUTSIDE main.swift on purpose: globals declared in main.swift
// are initialised in execution order, and anything declared after the run loop never initialises
// at all — which silently broke clause splitting.
import Foundation

// Spans are cut twice (once to build the question, once to read the answer); keep them identical.
func spansFor(_ text: String) -> [String] { searchSpans(text) }

/// Splits "open chrome on this screen and vs code on the other" into two commands.
/// Only splits when what FOLLOWS the connector starts with an action word, so "search for cats and
/// dogs" and "copy and paste" stay whole. Code does this, not the model: it is punctuation-level
/// work and a wrong split is far more confusing than a missed one.
let actionStarters = ["open", "close", "quit", "launch", "start", "go", "switch", "move", "put",
                      "maximi", "minimi", "scroll", "click", "press", "type", "search", "show",
                      "hide", "focus", "bring", "make", "resize", "snap", "tile"]
func splitClauses(_ text: String) -> [String] {
  let re = try! NSRegularExpression(pattern: "\\s*(?:,\\s*)?\\b(?:and then|then|and)\\b\\s*", options: .caseInsensitive)
  let ns = text as NSString
  var parts: [String] = []
  var last = 0
  for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
    let tail = ns.substring(from: m.range.location + m.range.length).lowercased()
    guard actionStarters.contains(where: { tail.hasPrefix($0) }) else { continue }
    let piece = ns.substring(with: NSRange(location: last, length: m.range.location - last))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if piece.count >= 3 { parts.append(piece); last = m.range.location + m.range.length }
  }
  let tail = ns.substring(from: last).trimmingCharacters(in: .whitespacesAndNewlines)
  if !tail.isEmpty { parts.append(tail) }
  return parts.count > 1 ? parts : [text]
}
