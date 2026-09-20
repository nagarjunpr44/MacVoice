// Every window of every app, addressable by name. The Accessibility API gives titles and frames
// without Screen Recording permission, which is what makes "go to my MAControl window" work.
import AppKit
import ApplicationServices

/// Set while a launched window is being placed, so short-lived CLI runs can wait for it.
let placementGroup = DispatchGroup()

struct Win {
  let app: String
  let title: String
  let frame: CGRect
  let minimized: Bool
  let el: AXUIElement
  let owner: NSRunningApplication
  /// What the user hears themselves say: "Code — MAControl".
  var label: String { title.isEmpty ? "\(app) window" : "\(app) — \(title)" }
  var screenName: String {
    guard let s = NSScreen.screens.max(by: { a, b in
      let ia = screenRectTopLeft(a).intersection(frame), ib = screenRectTopLeft(b).intersection(frame)
      return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
    }) else { return "?" }
    return s.auxiliaryTopLeftArea != nil ? "built-in" : s.localizedName
  }
}

private var winCache: (at: Date, wins: [Win])?

/// Windows change constantly, so the cache is short; the walk itself is one AX call per app.
func allWindows(limit: Int = 40) -> [Win] {
  if let c = winCache, Date().timeIntervalSince(c.at) < 3 { return c.wins }
  var out: [Win] = []
  for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    guard let name = app.localizedName, !isDenied(app.bundleIdentifier ?? "") else { continue }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 0.25)
    var w: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &w) == .success,
          let wins = w as? [AXUIElement] else { continue }
    for win in wins.prefix(12) {
      var t: CFTypeRef?, p: CFTypeRef?, z: CFTypeRef?, m: CFTypeRef?
      AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
      AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &p)
      AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &z)
      AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &m)
      var pt = CGPoint.zero, sz = CGSize.zero
      if let p, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
      if let z, CFGetTypeID(z) == AXValueGetTypeID() { AXValueGetValue(z as! AXValue, .cgSize, &sz) }
      if sz.width < 80 || sz.height < 60 { continue }          // panels and palettes, not windows
      out.append(Win(app: name, title: String(((t as? String) ?? "").prefix(60)),
                     frame: CGRect(origin: pt, size: sz), minimized: (m as? Bool) ?? false,
                     el: win, owner: app))
      if out.count >= limit { break }
    }
    if out.count >= limit { break }
  }
  winCache = (Date(), out)
  return out
}

func invalidateWindowCache() { winCache = nil }

/// Bring a window forward. Raising alone leaves the app unfocused, so activate it too.
@discardableResult
func focusWindow(_ w: Win) -> Bool {
  if w.minimized { AXUIElementSetAttributeValue(w.el, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
  let raised = AXUIElementPerformAction(w.el, kAXRaiseAction as CFString) == .success
  AXUIElementSetAttributeValue(w.el, kAXMainAttribute as CFString, kCFBooleanTrue)
  w.owner.activate()
  return raised
}

private func setFrame(_ w: Win, _ r: CGRect) {
  var p = r.origin, s = r.size
  // Position must be set before size, or a window that would fall off its current screen is clamped.
  if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w.el, kAXPositionAttribute as CFString, pv) }
  if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w.el, kAXSizeAttribute as CFString, sv) }
}

/// AX frames are top-left origin; NSScreen is bottom-left. Convert once, here.
private func usableArea(_ screen: NSScreen) -> CGRect {
  let full = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
  let v = screen.visibleFrame
  return CGRect(x: v.minX, y: full.maxY - v.maxY, width: v.width, height: v.height)
}

/// A screen's frame in AX coordinates (top-left origin), so it can be compared with window frames.
/// Mixing the two origins made "which screen is this on?" wrong, so windows never moved.
func screenRectTopLeft(_ s: NSScreen) -> CGRect {
  let full = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
  return CGRect(x: s.frame.minX, y: full.maxY - s.frame.maxY, width: s.frame.width, height: s.frame.height)
}

/// The screen holding most of the window, by overlap area — an edge-touching window matched nothing.
private func screenOf(_ w: Win) -> NSScreen {
  var best: (NSScreen, CGFloat)?
  for s in NSScreen.screens {
    let i = screenRectTopLeft(s).intersection(w.frame)
    let area = i.isNull ? 0 : i.width * i.height
    if area > (best?.1 ?? 0) { best = (s, area) }
  }
  return best?.0 ?? NSScreen.main ?? NSScreen.screens[0]
}

func applyWindowOp(_ op: String, _ w: Win) {
  let here = screenOf(w)
  switch op {
  case "focus": focusWindow(w)
  case "minimize": AXUIElementSetAttributeValue(w.el, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
  case "maximize":
    focusWindow(w); setFrame(w, usableArea(here))
  case "left_half", "right_half":
    focusWindow(w)
    let a = usableArea(here)
    setFrame(w, CGRect(x: op == "left_half" ? a.minX : a.midX, y: a.minY, width: a.width / 2, height: a.height))
  case let x where x.hasPrefix("screen:"):
    // No "already there" shortcut: a window that has just been created briefly reports a default
    // frame, which made this think it was already on the right screen and skip the move.
    guard let target = screenNamed(String(x.dropFirst(7)), relativeTo: here) else { focusWindow(w); return }
    focusWindow(w)
    let a = usableArea(target)
    let size = CGSize(width: min(w.frame.width, a.width), height: min(w.frame.height, a.height))
    setFrame(w, CGRect(x: a.midX - size.width / 2, y: a.midY - size.height / 2, width: size.width, height: size.height))
  case "other_screen":
    guard let target = NSScreen.screens.first(where: { $0 != here }) else { return }
    focusWindow(w)
    let a = usableArea(target)
    // Keep the window's proportions, just re-home it on the other display.
    let size = CGSize(width: min(w.frame.width, a.width), height: min(w.frame.height, a.height))
    setFrame(w, CGRect(x: a.midX - size.width / 2, y: a.midY - size.height / 2, width: size.width, height: size.height))
  default: focusWindow(w)
  }
  invalidateWindowCache()
}

/// Same dilution problem as tabs: 40 window titles spread the probability thin, so narrow the
/// field in code first and keep the original indices.
func shortlistWindows(_ wins: [Win], _ utterance: String, keep: Int = 14) -> [Int] {
  let stop: Set<String> = ["go", "to", "the", "my", "a", "in", "on", "that", "show", "me", "please",
                           "switch", "window", "windows", "move", "put", "open", "this"]
  let words = utterance.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    .filter { !stop.contains($0) && $0.count > 1 }
  guard !words.isEmpty else { return Array(wins.indices.prefix(keep)) }
  let scored = wins.indices.map { i -> (Int, Int) in
    let hay = wins[i].label.lowercased()
    return (i, words.reduce(0) { $0 + (hay.contains($1) ? $1.count : 0) })
  }
  let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
  if hits.isEmpty { return Array(wins.indices.prefix(keep)) }
  var out = hits.prefix(keep).map(\.0)
  for i in wins.indices where out.count < keep && !out.contains(i) { out.append(i) }
  return out
}

/// Places a just-launched app's window. Polls THAT app's AX windows directly: NSWorkspace's
/// running-application list is refreshed by run-loop notifications, so a background thread polling
/// it never sees an app that was launched a moment ago.
func placeWindow(of app: NSRunningApplication, named monitor: String, timeout: TimeInterval = 6) {
  placementGroup.enter()
  defer { placementGroup.leave() }
  let deadline = Date().addingTimeInterval(timeout)
  let ax = AXUIElementCreateApplication(app.processIdentifier)
  AXUIElementSetMessagingTimeout(ax, 0.3)
  while Date() < deadline {
    var w: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &w) == .success,
       let wins = w as? [AXUIElement], let first = wins.first {
      usleep(500_000)                       // let the app restore its saved frame first
      var p: CFTypeRef?, z: CFTypeRef?
      AXUIElementCopyAttributeValue(first, kAXPositionAttribute as CFString, &p)
      AXUIElementCopyAttributeValue(first, kAXSizeAttribute as CFString, &z)
      var pt = CGPoint.zero, sz = CGSize.zero
      if let p, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
      if let z, CFGetTypeID(z) == AXValueGetTypeID() { AXValueGetValue(z as! AXValue, .cgSize, &sz) }
      guard sz.width > 40, sz.height > 40 else { usleep(250_000); continue }
      let win = Win(app: app.localizedName ?? "", title: "", frame: CGRect(origin: pt, size: sz),
                    minimized: false, el: first, owner: app)
      applyWindowOp("screen:" + monitor, win)
      invalidateWindowCache()
      return
    }
    usleep(250_000)
  }
  NSLog("placeWindow: no window appeared for \(app.localizedName ?? "?")")
}

/// Which physical screen a name refers to. "other" is relative to where the window already is.
func screenNamed(_ name: String, relativeTo current: NSScreen) -> NSScreen? {
  switch name {
  case "builtin": return NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.screens.first
  case "external": return NSScreen.screens.first { $0.auxiliaryTopLeftArea == nil } ?? NSScreen.screens.last
  case "other": return NSScreen.screens.first { $0 != current }
  default: return nil
  }
}
