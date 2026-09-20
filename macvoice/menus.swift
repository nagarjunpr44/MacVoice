// Every menu command of the frontmost app, as sayable paths ("File > New Window").
// This is the widest control surface on macOS: it needs no keyboard shortcut and works in any
// native app. Cached per process, because walking the tree costs ~100-300 ms.
import AppKit
import ApplicationServices

struct MenuCmd { let path: String; let shortcut: String; let el: AXUIElement }

private var menuCache: [pid_t: (built: Date, cmds: [MenuCmd])] = [:]
// Menu items enable/disable with context (Zoom In is dead on a blank page), so the list must not
// go stale. A cold walk is ~300 ms and happens while you are still speaking, so a short TTL is cheap.
private let menuCacheTTL: TimeInterval = 25
private let menuQ = DispatchQueue(label: "menus")

private let modGlyphs: [(Int, String)] = [(1 << 17, "⇧"), (1 << 18, "⌃"), (1 << 19, "⌥"), (1 << 20, "⌘")]

private func shortcutOf(_ el: AXUIElement) -> String {
  var c: CFTypeRef?, m: CFTypeRef?
  AXUIElementCopyAttributeValue(el, kAXMenuItemCmdCharAttribute as CFString, &c)
  AXUIElementCopyAttributeValue(el, kAXMenuItemCmdModifiersAttribute as CFString, &m)
  guard let ch = c as? String, !ch.isEmpty else { return "" }
  // AX reports modifiers as a mask where bit 0 clear means Command is implied.
  let raw = (m as? Int) ?? 0
  var out = ""
  if raw & 1 == 0 { out += "⌘" }
  if raw & 2 != 0 { out += "⇧" }
  if raw & 4 != 0 { out += "⌥" }
  if raw & 8 != 0 { out += "⌃" }
  return out + ch.uppercased()
}

/// Walks AXMenuBar depth-first. Reading children does NOT open the menus on screen.
func menuCommands(for app: NSRunningApplication, limit: Int = 240, perMenuLimit: Int = 34, subLimit: Int = 6) -> [MenuCmd] {
  let pid = app.processIdentifier
  if let c = menuCache[pid], Date().timeIntervalSince(c.built) < menuCacheTTL { return c.cmds }
  let axApp = AXUIElementCreateApplication(pid)
  AXUIElementSetMessagingTimeout(axApp, 0.3)
  var mb: CFTypeRef?
  guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &mb) == .success, let mb else { return [] }
  var out: [MenuCmd] = []
  let deadline = Date().addingTimeInterval(1.5)

  func children(_ el: AXUIElement) -> [AXUIElement] {
    var c: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &c) == .success,
          let k = c as? [AXUIElement] else { return [] }
    return k
  }
  func title(_ el: AXUIElement) -> String {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
    return (t as? String) ?? ""
  }
  func enabled(_ el: AXUIElement) -> Bool {
    var e: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &e)
    return (e as? Bool) ?? true
  }
  // Long enumeration submenus (Text Encoding, Recently Closed, language lists) would otherwise
  // eat a whole menu's budget and hide the real commands further down. Cap EVERY submenu, so the
  // rule generalises instead of relying on a blocklist of names.
  @discardableResult
  func walk(_ el: AXUIElement, prefix: String, depth: Int) -> Int {
    guard depth <= 3, out.count < limit, Date() < deadline else { return 0 }
    let cap = depth >= 2 ? subLimit : perMenuLimit
    var taken = 0
    for item in children(el) {
      guard taken < cap, out.count < limit, Date() < deadline else { break }
      let t = title(item)
      if t.isEmpty { continue }                       // separators
      let path = prefix.isEmpty ? t : "\(prefix) > \(t)"
      let subs = children(item)                        // an AXMenuItem's submenu is its only child
      if let sub = subs.first, !children(sub).isEmpty {
        taken += walk(sub, prefix: path, depth: depth + 1)
      } else if enabled(item) {
        out.append(MenuCmd(path: path, shortcut: shortcutOf(item), el: item))
        taken += 1
      }
    }
    return taken
  }
  // Skip the Apple menu: its items are system-wide and mostly risky (Shut Down, Log Out).
  for bar in children(mb as! AXUIElement).dropFirst() {
    let t = title(bar)
    guard !t.isEmpty, let sub = children(bar).first else { continue }
    walk(sub, prefix: t, depth: 1)                     // each top-level menu gets its own budget
  }
  menuQ.sync { menuCache[pid] = (Date(), out) }
  return out
}

func invalidateMenuCache() { menuQ.sync { menuCache.removeAll() } }

/// Presses a menu item directly. No visible menu opening, no keystroke needed.
func pressMenu(_ cmd: MenuCmd) -> Bool {
  AXUIElementPerformAction(cmd.el, kAXPressAction as CFString) == .success
}
