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
                      "hide", "focus", "bring", "make", "resize", "snap", "tile", "dictate"]
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

/// Same idea as shortlistTabs/shortlistWindows: cut the candidate list down in code first.
/// Falls back to the FULL list when nothing matches by word, because a wrong shortlist that drops
/// the right element is far worse than a long list.
func shortlistElements(_ els: [El], _ utterance: String, keep: Int = 28) -> [Int] {
  guard els.count > keep else { return Array(els.indices) }
  let stop: Set<String> = ["the", "a", "an", "on", "in", "to", "this", "that", "my", "it",
                           "click", "press", "tap", "open", "go", "please", "current", "button"]
  let words = utterance.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    .filter { !stop.contains($0) && $0.count > 1 }
  guard !words.isEmpty else { return Array(els.indices.prefix(keep)) }
  let scored = els.indices.map { i -> (Int, Int) in
    let hay = els[i].label.lowercased()
    return (i, words.reduce(0) { $0 + (hay.contains($1) ? $1.count : 0) })
  }
  let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
  guard !hits.isEmpty else { return Array(els.indices.prefix(keep)) }
  var out = hits.prefix(keep).map(\.0)
  for i in els.indices where out.count < keep && !out.contains(i) { out.append(i) }
  return out
}
