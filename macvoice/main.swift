// macvoice: say (or type) a command -> ONE TypeSafe Jev request -> click / open / scroll / type / key.
// Dry-run by default (prints what it would do). Pass --live to act. Speech is recognised on-device;
// only text is sent to Jev: your words, the app name, and short labels of on-screen controls.
import AppKit
import ApplicationServices
import AVFoundation
import Speech

// MARK: options (globals first: main.swift runs top to bottom)
var live = true, alwaysOn = true, noScreen = false, demo = false, repl = false, snapOnly = false, micTest = false, menuList = false, tabList = false
var textCmd: String?, targetApp: String?, wake = "computer", silenceMs = 700, delaySec = -1.0, model = "jev-latest"
do {
  var a = Array(CommandLine.arguments.dropFirst())
  func next() -> String { a.isEmpty ? "" : a.removeFirst() }
  while !a.isEmpty {
    switch next() {
    case "--live": live = true
    case "--dry-run": live = false

    case "--no-screen": noScreen = true
    case "--demo": demo = true
    case "--repl": repl = true
    case "--snapshot": snapOnly = true
    case "--menus": menuList = true
    case "--tabs": tabList = true
    case "--mic-test": micTest = true
    case "--text": textCmd = next()
    case "--target": targetApp = next()
    case "--wake": wake = next().lowercased(); alwaysOn = false
    case "--silence": silenceMs = Int(next()) ?? 450
    case "--delay": delaySec = Double(next()) ?? 0
    case "--model": model = next()
    default: print("flags: --dry-run --wake WORD --mic-test --text \"cmd\" --target App --repl --demo --snapshot --silence MS --delay SEC --no-screen --model ID"); exit(2)
    }
  }
}
let textMode = textCmd != nil || repl || demo || snapOnly || menuList || tabList
// Launched from Finder there are no flags, so fall back to however you last left it.
if !textMode, UserDefaults.standard.object(forKey: "live") != nil { live = UserDefaults.standard.bool(forKey: "live") }

// MARK: safety knobs (all deterministic code, none of it asks the model)
let deniedApps = ["com.apple.keychainaccess", "com.apple.Passwords", "com.1password", "com.agilebits", "com.bitwarden",
                  "com.lastpass", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp"]
func isDenied(_ b: String) -> Bool { deniedApps.contains { b.hasPrefix($0) } }
let riskRe = try! NSRegularExpression(pattern: "\\b(delete|remove|erase|trash|send|submit|pay|purchase|buy|order|checkout|confirm|sign out|log out|logout|quit|format|transfer|publish|post|empty|discard|reset|uninstall|unsubscribe)\\b", options: .caseInsensitive)
func risky(_ s: String) -> Bool { riskRe.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
let emailRe = try! NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: .caseInsensitive)
let digitsRe = try! NSRegularExpression(pattern: "\\d{6,}")
func clean(_ s: String) -> String {  // what a label looks like after redaction, before it leaves the Mac
  var t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
  for (re, rep) in [(emailRe, "<email>"), (digitsRe, "<num>")] {
    t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: rep)
  }
  return String(t.prefix(60))
}
func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
func beep(_ n: String) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); p.arguments = ["/System/Library/Sounds/\(n).aiff"]; try? p.run() }

// MARK: reading the screen (Accessibility tree)
struct El { let id: String; let axRole: String; let role: String; let label: String; let frame: CGRect; let ref: AXUIElement? }
struct Screen { var app: String; var bundle: String; var els: [El]; var window: CGRect; var electron: Bool; var menus: [MenuCmd] = []; var running: NSRunningApplication? = nil; var tabs: [Tab] = [] }
let roleNames = ["AXButton": "button", "AXLink": "link", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXMenuItem": "menuitem",
                 "AXMenuBarItem": "menu", "AXPopUpButton": "popup", "AXMenuButton": "popup", "AXComboBox": "combobox",
                 "AXTextField": "field", "AXTextArea": "field", "AXSlider": "slider", "AXDisclosureTriangle": "disclosure"]
let axNames: [CFString] = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                           kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
                           kAXChildrenAttribute].map { $0 as CFString }
func axAttrs(_ el: AXUIElement) -> [String: Any] {  // one IPC round trip per node
  var out: CFArray?
  guard AXUIElementCopyMultipleAttributeValues(el, axNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
        let arr = out as? [Any] else { return [:] }
  var d: [String: Any] = [:]
  for (i, v) in arr.enumerated() {
    let cf = v as AnyObject
    if CFGetTypeID(cf) == AXValueGetTypeID(), AXValueGetType(cf as! AXValue) == .axError { continue }
    d[axNames[i] as String] = v
  }
  return d
}
func axPoint(_ v: Any?) -> CGPoint? {
  guard let o = v, CFGetTypeID(o as AnyObject) == AXValueGetTypeID() else { return nil }
  var p = CGPoint.zero; return AXValueGetValue(o as! AXValue, .cgPoint, &p) ? p : nil
}
func axSize(_ v: Any?) -> CGSize? {
  guard let o = v, CFGetTypeID(o as AnyObject) == AXValueGetTypeID() else { return nil }
  var s = CGSize.zero; return AXValueGetValue(o as! AXValue, .cgSize, &s) ? s : nil
}
func childText(_ el: AXUIElement) -> String {  // icon+text buttons keep their label in a child StaticText
  var c: CFTypeRef?
  guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &c) == .success, let kids = c as? [AXUIElement] else { return "" }
  for k in kids.prefix(4) {
    var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(k, kAXValueAttribute as CFString, &v) == .success, let s = v as? String, !s.isEmpty { return s }
  }
  return ""
}
func snapshot(_ app: NSRunningApplication) -> Screen {
  let bundle = app.bundleIdentifier ?? ""
  let electron = app.bundleURL.map { FileManager.default.fileExists(atPath: $0.path + "/Contents/Frameworks/Electron Framework.framework") } ?? false
  var scr = Screen(app: app.localizedName ?? "?", bundle: bundle, els: [], window: .zero, electron: electron)
  let root = AXUIElementCreateApplication(app.processIdentifier)
  AXUIElementSetMessagingTimeout(root, 0.25)
  AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)  // makes Chrome/Electron expose web content
  var w: CFTypeRef?
  var starts: [AXUIElement] = []
  if AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &w) == .success, let w { starts.append(w as! AXUIElement) }
  else if AXUIElementCopyAttributeValue(root, kAXMainWindowAttribute as CFString, &w) == .success, let w { starts.append(w as! AXUIElement) }
  var found: [(AXUIElement, String, String, String, CGRect)] = []  // ref, axRole, role, label, frame
  func consider(_ el: AXUIElement, _ d: [String: Any], clipToWindow: Bool) {
    guard let role = d[kAXRoleAttribute] as? String, let name = roleNames[role],
          (d[kAXEnabledAttribute] as? Bool) != false, (d[kAXSubroleAttribute] as? String) != "AXSecureTextField",
          let p = axPoint(d[kAXPositionAttribute]), let z = axSize(d[kAXSizeAttribute]), z.width > 2, z.height > 2 else { return }
    let f = CGRect(origin: p, size: z)
    if clipToWindow, !scr.window.isEmpty, !f.intersects(scr.window) { return }
    var lab = ""
    for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute] {
      guard let t = d[k] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      if k == kAXHelpAttribute && t.count > 25 { continue }  // help is a tooltip sentence, not a name
      lab = t; break
    }
    found.append((el, role, name, lab, f))
  }
  func walk() {
    let deadline = Date().addingTimeInterval(0.6)
    var queue = starts, i = 0
    while i < queue.count, i < 2500, Date() < deadline {
      let el = queue[i]; i += 1
      let d = axAttrs(el)
      if (d[kAXRoleAttribute] as? String) == "AXWindow", scr.window.isEmpty, let p = axPoint(d[kAXPositionAttribute]), let z = axSize(d[kAXSizeAttribute]) {
        scr.window = CGRect(origin: p, size: z)
      }
      consider(el, d, clipToWindow: true)
      if let ch = d[kAXChildrenAttribute] as? [AXUIElement] { queue.append(contentsOf: ch) }
    }
  }
  walk()
  // Electron and Chrome build their tree lazily once AXManualAccessibility is set, so the first walk
  // comes back nearly empty. Give it a moment and walk again. ponytail: one retry, not a poll loop.
  if found.count < 5, electron || browsers.contains(bundle) {
    usleep(400_000); found.removeAll(); walk()
  }
  var mb: CFTypeRef?  // menu bar: top-level titles only (File, Edit, ...); an open menu shows up in the window walk on the next command
  if AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &mb) == .success, let mb,
     let kids = axAttrs(mb as! AXUIElement)[kAXChildrenAttribute] as? [AXUIElement] {
    for k in kids { consider(k, axAttrs(k), clipToWindow: false) }
  }
  var fallbacks = 0
  found = found.map { f in
    guard f.3.isEmpty, fallbacks < 40, f.2 != "field" else { return f }
    fallbacks += 1; return (f.0, f.1, f.2, childText(f.0), f.4)
  }
  let kept = found.filter { !$0.3.trimmingCharacters(in: .whitespaces).isEmpty }
    .sorted { ($0.4.minY / 12).rounded() != ($1.4.minY / 12).rounded() ? $0.4.minY < $1.4.minY : $0.4.minX < $1.4.minX }
    .prefix(150)
  scr.els = kept.enumerated().map { El(id: "e\($0.offset)", axRole: $0.element.1, role: $0.element.2, label: clean($0.element.3), frame: $0.element.4, ref: $0.element.0) }
  return scr
}
func prepareScreen() -> Screen {
  // --target pins every command to one app, so you can watch the log in your terminal without the
  // terminal itself being the thing that gets scrolled.
  let chosen = targetApp.flatMap { t in
    NSWorkspace.shared.runningApplications.first {
      $0.activationPolicy == .regular && ($0.localizedName ?? "").localizedCaseInsensitiveContains(t)
    }
  }
  guard let app = chosen ?? NSWorkspace.shared.frontmostApplication else { return Screen(app: "?", bundle: "", els: [], window: .zero, electron: false) }
  let base = Screen(app: app.localizedName ?? "?", bundle: app.bundleIdentifier ?? "", els: [], window: .zero, electron: false)
  if noScreen || isDenied(base.bundle) { return base }  // nothing about the screen is read or sent
  // Kept serial on purpose: running these three concurrently was SLOWER (2.0 s vs 1.2 s), because
  // AX queries and Apple events all queue behind the target app's main thread. The real fix is the
  // caches below (menus 25 s, tabs 6 s) plus starting this the moment speech begins.
  // Tabs FIRST. The AX element walk and the menu walk both hammer the target app's main thread,
  // and an Apple event queued behind them times out — which is how Chrome's 26 tabs silently
  // became 0 while Brave (idle) still returned its 4.
  let tabs = allBrowserTabs()
  var s = snapshot(app)
  s.running = app
  s.menus = menuCommands(for: app)
  s.tabs = tabs
  return s
}
func demoScreen() -> Screen {
  let items = [("button", "Cancel"), ("button", "Submit"), ("button", "Save draft"), ("link", "Pricing"), ("link", "Docs"), ("field", "Search"),
               ("checkbox", "Remember me"), ("button", "Sign in"), ("menu", "File"), ("menu", "Edit"), ("button", "Delete account"), ("link", "Contact sales")]
  return Screen(app: "Demo", bundle: "demo", els: items.enumerated().map { El(id: "e\($0.offset)", axRole: "AXButton", role: $0.element.0, label: $0.element.1, frame: .zero, ref: nil) }, window: .zero, electron: false)
}

// MARK: doing things
let browsers = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]
let nativePress: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle"]
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func cgClick(_ p: CGPoint) {
  let src = CGEventSource(stateID: .hidSystemState)
  for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    post(CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)); usleep(8000)
  }
}
func click(_ e: El, _ s: Screen) {
  guard let ref = e.ref else { return }
  let web = browsers.contains(s.bundle) || s.electron  // AXPress "succeeds" and does nothing on web content
  if !web, nativePress.contains(e.axRole), AXUIElementPerformAction(ref, kAXPressAction as CFString) == .success { return }
  cgClick(CGPoint(x: e.frame.midX, y: e.frame.midY))
}
func scroll(_ dir: String, _ s: Screen) {
  // AX frames are top-left origin (what CGWarp wants); NSEvent.mouseLocation is bottom-left, so it
  // has to be flipped or the cursor jumps to the wrong half of the screen and scrolls the wrong window.
  var fallback = NSEvent.mouseLocation
  if let h = NSScreen.screens.first(where: { $0.frame.contains(fallback) })?.frame.maxY ?? NSScreen.main?.frame.maxY {
    fallback.y = h - fallback.y
  }
  let c = s.window.isEmpty ? fallback : CGPoint(x: s.window.midX, y: s.window.midY)
  CGWarpMouseCursorPosition(c)
  let page = Int32(max(300, s.window.height * 0.85))
  let (total, sign): (Int32, Int32) = ["down": (350, -1), "up": (350, 1), "page_down": (page, -1), "page_up": (page, 1), "bottom": (30000, -1), "top": (30000, 1)][dir] ?? (0, 0)
  var left = total
  while left > 0 { let step = min(left, dir == "top" || dir == "bottom" ? 1500 : 70); post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: sign * step, wheel2: 0, wheel3: 0)); left -= step; usleep(6000) }
}
let keyTable: [(String, CGKeyCode, CGEventFlags, String)] = [
  ("new_tab", 17, .maskCommand, "Open a new tab"), ("close_tab", 13, .maskCommand, "Close the current tab or window"),
  ("new_window", 45, .maskCommand, "Open a new window"), ("back", 33, .maskCommand, "Go back to the previous page or screen"),
  ("forward", 30, .maskCommand, "Go forward"), ("reload", 15, .maskCommand, "Reload or refresh the page"),
  ("copy", 8, .maskCommand, "Copy the selection"), ("cut", 7, .maskCommand, "Cut the selection"), ("paste", 9, .maskCommand, "Paste from the clipboard"),
  ("undo", 6, .maskCommand, "Undo the last action"), ("redo", 6, [.maskCommand, .maskShift], "Redo the last undone action"),
  ("select_all", 0, .maskCommand, "Select everything"), ("save", 1, .maskCommand, "Save the current document"),
  ("find", 3, .maskCommand, "Find or search within the page or document"), ("address_bar", 37, .maskCommand, "Focus the browser address bar"),
  ("next_tab", 48, .maskControl, "Switch to the next tab"), ("prev_tab", 48, [.maskControl, .maskShift], "Switch to the previous tab"),
  ("enter", 36, [], "Press the Return or Enter key"), ("escape", 53, [], "Press Escape, cancel or dismiss"),
  ("tab", 48, [], "Press the Tab key to move to the next field"), ("minimize", 46, .maskCommand, "Minimize the window"),
  ("hide_app", 4, .maskCommand, "Hide the current application"), ("quit_app", 12, .maskCommand, "Quit the current application"),
]
func pressKey(_ name: String) {
  guard let k = keyTable.first(where: { $0.0 == name }) else { return }
  let src = CGEventSource(stateID: .hidSystemState)
  for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: k.1, keyDown: down); e?.flags = k.2; post(e); usleep(5000) }
}
func typeText(_ s: String) {
  let src = CGEventSource(stateID: .hidSystemState), u = Array(s.utf16)
  var i = 0
  while i < u.count {
    let chunk = Array(u[i..<min(i + 16, u.count)])
    for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down); e?.flags = []; e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk); post(e) }
    i += 16; usleep(4000)
  }
}
func openApp(_ url: URL) { let c = NSWorkspace.OpenConfiguration(); c.activates = true; NSWorkspace.shared.openApplication(at: url, configuration: c) { _, _ in } }

// MARK: Jev
struct Answers {
  let raw: [String: Any]
  func choice(_ k: String) -> (String, Double)? {
    guard let a = raw[k] as? [String: Any], let c = a["choice"] as? String, let cf = a["confidence"] as? Double else { return nil }
    return (c, cf)
  }
  func noul(_ k: String) -> Double { ((raw[k] as? [String: Any])?["noul"] as? Double) ?? 0 }
  func top(_ k: String, _ n: Int) -> [(String, Double)] {
    let p = ((raw[k] as? [String: Any])?["probabilities"] as? [String: Double]) ?? [:]
    return p.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
  }
}
final class Jev {
  let key: String, session: URLSession
  init(key: String) {
    self.key = key
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 8; c.httpMaximumConnectionsPerHost = 2; c.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: c)
  }
  func warm() async {  // opens the TLS connection ahead of time (first request on a cold connection costs ~700 ms)
    var r = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/models")!)
    r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    _ = try? await session.data(for: r)
  }
  func ask(state: [String: Any], questions: [String: Any]) async throws -> (Answers, Int) {
    var r = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
    r.httpMethod = "POST"
    r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try JSONSerialization.data(withJSONObject: ["state": state, "model": model, "questions": questions])
    let (data, resp) = try await session.data(for: r)
    guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let a = j["answers"] as? [String: Any] else { throw NSError(domain: "jev", code: (resp as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8)?.prefix(200).description ?? ""]) }
    return (Answers(raw: a), ((j["usage"] as? [String: Any])?["input_tokens"] as? Int) ?? 0)
  }
}
func loadKey() -> String? {
  if let k = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !k.isEmpty { return k }
  let exeDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
  // last two reach macvoice/.env and MAControl/.env from inside macvoice.app/Contents/MacOS
  for p in [FileManager.default.currentDirectoryPath + "/.env", exeDir + "/.env", exeDir + "/../.env",
            exeDir + "/../../../.env", exeDir + "/../../../../.env"] {
    guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
    for l in s.split(separator: "\n") where l.hasPrefix("TYPESAFE_API_KEY=") {
      return String(l.dropFirst("TYPESAFE_API_KEY=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r"))
    }
  }
  return nil
}
func installedApps() -> [String: URL] {
  var m: [String: URL] = [:]
  for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
    for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".app") { m[String(f.dropLast(4))] = URL(fileURLWithPath: dir + "/" + f) }
  }
  return m
}
func questions(_ s: Screen, _ apps: [String: URL], _ rawUtterance: String) -> [String: Any] {
  let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { $0.localizedName }.filter { apps[$0] != nil }
  let names = Array((running + apps.keys.sorted()).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(254))
  var appOpts: [String: Any] = ["none": "No application is named"]
  for n in names { appOpts[n] = NSNull() }
  var keyOpts: [String: Any] = ["none": "No keyboard action is requested"]
  for k in keyTable { keyOpts[k.0] = k.3 }
  var q: [String: Any] = [
    "is_command": ["type": "noul", "instructions": "The utterance tells the computer to do something. This includes naming a button, link or menu to click ('delete account', 'save draft'), an app to open, an editing or navigation action ('copy that', 'undo', 'go back', 'new tab'), scrolling, and text to type. It excludes conversation between people, questions asked of a person, and thinking out loud.", "criteria": ["true": "An instruction addressed to the computer, even a very short one naming only a control", "false": "Conversation, a question, a remark, or speech not addressed to the computer"]],
    "destructive": ["type": "noul", "instructions": "Carrying out the utterance would delete, send, submit, purchase, quit, sign out or otherwise be hard to undo."],
    "intent": ["type": "choice", "instructions": "What operation does the utterance ask the computer to perform? An utterance that only names a control, such as 'delete account' or 'save draft', is asking to click that control.", "criteria": [
      "click": "Click, press, select, toggle, focus or open a control shown on screen, such as a button, link, checkbox, tab, field or menu. Also covers an utterance that just names such a control.",
      "open_app": "Open, launch or switch to an application by name",
      "scroll": "Scroll, move or jump the current view up, down, to the top or to the bottom",
      "type_text": "Type, write or enter specific words into the focused field",
      "press_key": "Perform an editing, navigation or window action normally done with a keyboard shortcut: copy, cut, paste, undo, redo, select all, save, find, new tab, close tab, next or previous tab, back, forward, reload, enter, escape, minimise, hide or quit",
      "search": "Search the web, or a specific site such as YouTube, Wikipedia, GitHub, Amazon or Maps, for something",
      "switch_tab": "Go to, switch to or find an already-open browser tab",
      "menu_item": "Invoke a command from the application's own menus, such as a preference, a formatting option, an export or a view setting, that is not a visible on-screen button",
      "none": "None of the above"]],
    "scroll": ["type": "choice", "instructions": "In which direction and how far does the utterance ask to scroll?", "criteria": [
      "down": "Scroll down a little", "up": "Scroll up a little", "page_down": "Scroll down a full page", "page_up": "Scroll up a full page",
      "bottom": "Scroll all the way to the bottom or end", "top": "Scroll all the way to the top or start"]],
    "key": ["type": "choice", "instructions": "Which keyboard action does the utterance ask for?", "criteria": keyOpts],
    "app": ["type": "choice", "instructions": "Which application does the utterance ask to open or switch to?", "criteria": appOpts],
  ]
  if !s.tabs.isEmpty {
    var t: [String: Any] = ["none": "No open tab matches"]
    for i in shortlistTabs(s.tabs, rawUtterance) { t["t\(i)"] = "\(s.tabs[i].title)  [\(s.tabs[i].app)]" }
    q["tab"] = ["type": "choice", "instructions": "The user wants to switch to a browser tab that is already open. These are the titles of the open tabs. Which one is the user referring to? A tab matches when its title names the same page, video, site or topic the user mentioned, even if the wording differs and the title carries extra text such as a channel name, a view count or a site suffix. Choose none only when no tab is plausibly about what the user named.", "criteria": t]
  }
  let spans = searchSpans(rawUtterance)
  if !spans.isEmpty {
    var sp: [String: Any] = [:]
    for (i, v) in spans.enumerated() { sp["s\(i)"] = "the text: \(v)" }
    q["query"] = ["type": "choice", "instructions": "If the utterance asks to search for something, which of these candidate texts is exactly the thing to search for? Pick the one that is the search terms only, without words like 'search for' or the name of the website.", "criteria": sp]
  }
  q["engine"] = ["type": "choice", "instructions": "If the utterance asks to search, which website should be searched?", "criteria": [
    "google": "A general web search with no particular site named",
    "youtube": "Videos, music, or YouTube is named",
    "wikipedia": "An encyclopaedia article, or Wikipedia is named",
    "github": "Code or repositories, or GitHub is named",
    "amazon": "Shopping or buying a product, or Amazon is named",
    "google_maps": "A place, directions, or a map",
    "duckduckgo": "DuckDuckGo is named"]]
  if !s.menus.isEmpty {
    var m: [String: Any] = ["none": "No menu command matches"]
    for (i, c) in s.menus.enumerated() { m["m\(i)"] = c.shortcut.isEmpty ? c.path : "\(c.path)  (\(c.shortcut))" }
    q["menu"] = ["type": "choice", "instructions": "Which command from \(s.app)'s menus does the utterance ask for? These are the application's own menu commands, written as 'Menu > Item'. Choose none if nothing matches.", "criteria": m]
  }
  if !s.els.isEmpty {
    var t: [String: Any] = ["none": "No listed element matches"]
    for e in s.els { t[e.id] = "\(e.role): \(e.label)" }
    q["target"] = ["type": "choice", "instructions": "Which listed on-screen element does the utterance ask to click, press, select, toggle, focus or open? Choose none if no listed element matches.", "criteria": t]
  }
  return q
}

// MARK: deciding
var pending: (desc: String, run: () -> Void, expires: Date)?
var busy = false
let confirmWords: Set<String> = ["confirm", "yes", "do it", "go ahead", "yes confirm"], cancelWords: Set<String> = ["cancel", "no", "stop", "never mind", "nevermind"]
func f2(_ x: Double) -> String { String(format: "%.2f", x) }
/// Returns the winning option and its probability, gated on probability OR confidence.
func pick(_ ans: Answers, _ key: String, _ minP: Double, _ minC: Double) -> (String, Double)? {
  guard let (choice, conf) = ans.choice(key), let (topId, p) = ans.top(key, 1).first, topId == choice,
        p >= minP || conf >= minC else { return nil }
  return (choice, p)
}
func handle(_ heard: String, snap: Task<Screen, Never>?, voice: Bool, jev: Jev, apps: [String: URL]) async {
  if muted { return }
  if busy { print("  (busy, dropped: \(heard))"); return }
  busy = true; defer { busy = false }
  let t0 = Date()
  var text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
  if voice && !alwaysOn {
    guard let r = text.range(of: "^(hey |ok |okay )?\(wake)\\b[,.!? ]*", options: [.regularExpression, .caseInsensitive]) else {
      print("  · heard \"\(text)\" — ignored, start with \"\(wake)\"")  // proves the mic works
      ui(.idle)
      return
    }
    text = String(text[r.upperBound...])
  }
  guard !text.isEmpty else { beep("Tink"); print("  · listening"); return }
  print("▶ \"\(text)\"")
  ui(.thinking(text))
  let low = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
  if let p = pending, p.expires > Date() {
    if confirmWords.contains(low) { pending = nil; print("  ✓ confirmed: \(p.desc)"); p.run(); beep("Pop"); return }
    if cancelWords.contains(low) { pending = nil; print("  ✗ cancelled"); return }
  }
  let screen: Screen
  if demo { screen = demoScreen() } else if let snap { screen = await snap.value } else { screen = prepareScreen() }
  let axMs = ms(t0)
  let tj = Date()
  let ans: Answers, tokens: Int
  do { (ans, tokens) = try await jev.ask(state: ["utterance": text, "frontmost_app": screen.app], questions: questions(screen, apps, text)) }
  catch { print("  ✗ Jev error: \(error.localizedDescription)"); beep("Basso"); return }
  let jevMs = ms(tj)
  let isCmd = ans.noul("is_command"), dest = ans.noul("destructive")
  // Without a wake word this Noul is the ONLY thing between overheard conversation and a real
  // action, so it needs more margin than when "computer" was also required.
  let cmdGate = alwaysOn ? 0.7 : 0.5
  guard isCmd >= cmdGate else { print("  · ignored, not a command (\(f2(isCmd)))"); ui(.idle); return }
  // Gate on the winning option's probability, not `confidence`. Overlapping-but-equivalent intents
  // (menu_item vs press_key for "new private window") split the distribution and depress confidence
  // even when the top choice is right and either route would do the same thing.
  let intentTop = ans.top("intent", 1).first
  guard let (intent, ic) = ans.choice("intent"), intent != "none",
        let ip = intentTop?.1, ip >= 0.5 || ic >= 0.55 else {
    print("  ✗ not sure what you want: \(ans.top("intent", 3).map { "\($0.0) p\(f2($0.1))" }.joined(separator: ", ")) · conf \(f2(ans.choice("intent")?.1 ?? 0))")
    ui(.fail("not sure what you mean")); beep("Basso"); return
  }
  if isDenied(screen.bundle) && intent != "open_app" { print("  ✗ \(screen.app) is on the deny list; only \"open <app>\" works here"); beep("Basso"); return }
  var desc = "", isRisky = dest >= 0.5, run: () -> Void = {}, why = ""
  switch intent {
  case "click":
    guard let (tid, tc) = pick(ans, "target", 0.40, 0.55), tid != "none", let el = screen.els.first(where: { $0.id == tid }) else {
      let alts = ans.top("target", 3).compactMap { p in screen.els.first { $0.id == p.0 }.map { "\($0.role) \"\($0.label)\" \(f2(p.1))" } }
      print("  ✗ no confident target. closest: \(alts.joined(separator: " | ")) (\(screen.els.count) elements seen in \(screen.app))"); beep("Basso"); return
    }
    desc = "click \(el.role) \"\(el.label)\" in \(screen.app) (\(f2(tc)))"
    if risky(el.label) || risky(text) { isRisky = true; why = " [risk word]" }
    run = { click(el, screen) }
  case "open_app":
    guard let (a, ac) = pick(ans, "app", 0.45, 0.55), a != "none", let url = apps[a] else { print("  ✗ which app? \(ans.top("app", 3).map { "\($0.0) \(f2($0.1))" }.joined(separator: ", "))"); beep("Basso"); return }
    desc = "open \(a) (\(f2(ac)))"; isRisky = false; run = { openApp(url) }
  case "scroll":
    guard let (d, dc) = pick(ans, "scroll", 0.45, 0.55) else { print("  ✗ which way to scroll?"); return }
    desc = "scroll \(d) in \(screen.app) (\(f2(dc)))"; isRisky = false; run = { scroll(d, screen) }
  case "press_key":
    guard let (k, kc) = pick(ans, "key", 0.45, 0.55), k != "none" else { print("  ✗ which key? \(ans.top("key", 3).map { "\($0.0) \(f2($0.1))" }.joined(separator: ", "))"); return }
    desc = "press \(k) in \(screen.app) (\(f2(kc)))"; isRisky = k == "quit_app" || dest >= 0.5; run = { pressKey(k) }
  case "search":
    guard let (sid, sc) = ans.choice("query"), let qi = Int(sid.dropFirst()), qi < spansFor(text).count else {
      print("  ✗ could not tell what to search for"); beep("Basso"); return
    }
    let query = spansFor(text)[qi]
    let engine = ans.choice("engine").map { $0.0 } ?? "google"
    let browser = scriptableBrowsers.contains(screen.app) ? screen.app : "Safari"
    desc = "search \(engine) for \"\(query)\" in \(browser) (\(f2(sc)))"
    isRisky = false
    run = { _ = webSearch(query, engine: engine, in: browser) }
  case "switch_tab":
    guard let (tid, tc) = pick(ans, "tab", 0.40, 0.55), tid != "none",
          let ti = Int(tid.dropFirst()), ti < screen.tabs.count else {
      let alts = ans.top("tab", 4).map { p -> String in
        guard p.0 != "none", let i = Int(p.0.dropFirst()), i < screen.tabs.count else { return "none \(f2(p.1))" }
        return "\(screen.tabs[i].title.prefix(30)) \(f2(p.1))"
      }
      print("  ✗ no confident tab. closest: \(alts.joined(separator: " | ")) (\(screen.tabs.count) tabs)"); beep("Basso"); return
    }
    let tb = screen.tabs[ti]
    desc = "tab \"\(tb.title.prefix(40))\" in \(tb.app) window \(tb.window) (\(f2(tc)))"
    isRisky = false
    run = { _ = focusTab(tb) }
  case "menu_item":
    guard let (mid, mc) = pick(ans, "menu", 0.45, 0.55), mid != "none",
          let idx = Int(mid.dropFirst()), idx < screen.menus.count else {
      let alts = ans.top("menu", 3).compactMap { p in Int(p.0.dropFirst()).flatMap { i in i < screen.menus.count ? "\(screen.menus[i].path) \(f2(p.1))" : nil } }
      print("  ✗ no confident menu command. closest: \(alts.joined(separator: " | "))"); beep("Basso"); return
    }
    let cmd = screen.menus[idx]
    desc = "menu \(cmd.path) in \(screen.app) (\(f2(mc)))"
    if risky(cmd.path) || risky(text) { isRisky = true; why = " [risk word]" }
    run = { if !pressMenu(cmd) { print("  ! menu press failed; try saying the shortcut instead") } }
  case "type_text":
    guard let r = text.range(of: "\\b(?:type|write|enter|dictate|say)\\b\\s+(.+)$", options: [.regularExpression, .caseInsensitive]) else { print("  ✗ say what to type: \"type hello world\""); return }
    let payload = String(text[r]).replacingOccurrences(of: "^\\S+\\s+", with: "", options: .regularExpression)
    desc = "type \"\(payload)\" into \(screen.app)"; isRisky = false; run = { typeText(payload) }
  default: return
  }
  print("  cmd \(f2(isCmd)) · intent \(intent) p\(f2(intentTop?.1 ?? 0))/c\(f2(ic)) · destructive \(f2(dest)) · \(screen.els.count) elements, \(screen.menus.count) menus, \(screen.tabs.count) tabs, \(tokens) tokens")
  print("  ⏱ read screen \(axMs) ms · Jev \(jevMs) ms · total \(ms(t0)) ms")
  let act = live && !demo
  if isRisky {
    print("  ⚠ risky\(why): \(desc)")
    if !act { print("  DRY-RUN: would ask for confirmation"); return }
    if voice { pending = (desc, run, Date().addingTimeInterval(10)); print("  say \"confirm\" within 10 s (or \"cancel\")"); ui(.warn("say \"confirm\": " + desc)); beep("Tink") }
    else { print("  proceed? [y/N] ", terminator: ""); if readLine()?.lowercased().hasPrefix("y") == true { run(); beep("Pop") } }
    return
  }
  if act {
    print("  ✓ \(desc)")
    if targetApp != nil, let a = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == screen.app }), !a.isActive {
      a.activate(); usleep(120_000)  // focus it first or keystrokes go to whatever you are looking at
    }
    run(); beep("Pop"); ui(.ok(desc))
  } else { print("  DRY-RUN: would \(desc)"); ui(.warn("dry-run: " + desc)) }
}

// MARK: listening (on-device speech recognition; a command ends after `silenceMs` without new words)
final class Listener {
  let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
  let engine = AVAudioEngine(), q = DispatchQueue(label: "listener")
  var req: SFSpeechAudioBufferRecognitionRequest?, task: SFSpeechRecognitionTask?, timer: DispatchSourceTimer?
  var last = "", changed = Date(), started = false, peak: Float = 0, ticks = 0
  let onStart: () -> Void, onDone: (String) -> Void
  init(onStart: @escaping () -> Void, onDone: @escaping (String) -> Void) { self.onStart = onStart; self.onDone = onDone }
  func run() {
    SFSpeechRecognizer.requestAuthorization { st in
      guard st == .authorized else { print("Speech recognition not allowed: System Settings > Privacy & Security > Speech Recognition"); exit(1) }
      AVCaptureDevice.requestAccess(for: .audio) { ok in
        print("  auth: speech=\(st.rawValue) (3=authorized), microphone=\(ok)")
        guard ok else { print("Microphone not allowed: System Settings > Privacy & Security > Microphone"); exit(1) }
        self.q.async { self.begin(); self.startEngine() }
      }
    }
  }
  func startEngine() {
    let input = engine.inputNode
    let fmt = input.outputFormat(forBus: 0)
    print("  mic: \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch · on-device supported: \(rec.supportsOnDeviceRecognition) · available: \(rec.isAvailable)")
    guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
      print("  ! no usable microphone input. Check System Settings > Privacy & Security > Microphone for macvoice."); exit(1)
    }
    input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] b, _ in
      guard let self else { return }
      self.req?.append(b)
      if let ch = b.floatChannelData?[0] {  // drives the waveform, and --mic-test
        var peak: Float = 0
        for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[i])) }
        self.peak = max(self.peak, peak)
        micLevel = max(micLevel * 0.82, min(peak * 3.2, 1))  // decay + gain, so quiet speech still moves
      }
    }
    engine.prepare()
    do { try engine.start() } catch { print("mic error: \(error)"); exit(1) }
    let t = DispatchSource.makeTimerSource(queue: q)
    t.schedule(deadline: .now(), repeating: .milliseconds(40))
    t.setEventHandler { [weak self] in self?.tick() }
    t.resume(); timer = t
    print(alwaysOn ? "listening — just say the command, e.g. \"open safari\"" : "listening… say \"\(wake), open safari\"")
  }
  func begin() {
    let r = SFSpeechAudioBufferRecognitionRequest()
    r.shouldReportPartialResults = true
    if rec.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }  // audio never leaves the Mac
    req = r; last = ""; started = false
    task = rec.recognitionTask(with: r) { [weak self] res, err in
      self?.q.async {
        guard let self, self.req === r else { return }
        if let res {
          let t = res.bestTranscription.formattedString
          if t != self.last { self.last = t; self.changed = Date(); if !self.started && !t.isEmpty { self.started = true; self.onStart() } }
          if res.isFinal { self.fire() }
        } else if let err {
          let e = err as NSError
          // 1101/203 = no speech yet, normal. Anything else is a real fault and used to be swallowed.
          if !(e.code == 1101 || e.code == 203 || e.code == 301) {
            print("  ! speech error \(e.domain) \(e.code): \(e.localizedDescription)")
          }
          self.q.asyncAfter(deadline: .now() + 0.3) { if self.req === r { self.fire() } }
        }
      }
    }
  }
  /// End-of-utterance. SFSpeechRecognizer emits partials in bursts, and the gap AFTER the first
  /// word is routinely longer than the gap between later words — so a flat timer chopped
  /// "open chrome" into "open" + "chrome". Short transcripts must wait considerably longer.
  private var quietNeeded: Double {
    let words = last.split(whereSeparator: { $0 == " " }).count
    if words <= 1 { return Double(silenceMs) * 2.4 }   // "open" might still become "open chrome"
    if words == 2 { return Double(silenceMs) * 1.4 }
    return Double(silenceMs)
  }
  func tick() {
    if micTest {
      ticks += 1
      if ticks % 25 == 0 {  // once a second
        let bars = Int(min(peak, 1) * 40)
        print("  level [\(String(repeating: "#", count: bars))\(String(repeating: ".", count: 40 - bars))] \(String(format: "%.3f", peak))\(last.isEmpty ? "" : "  heard: \(last)")")
        peak = 0
      }
      if ticks > 375 { print("\nmic test done. Silent bars = macOS is not giving us audio; bars but no text = speech engine problem."); exit(0) }
    }
    if !last.isEmpty, Date().timeIntervalSince(changed) * 1000 > quietNeeded { fire() }
  }
  func fire() {
    let text = last
    req?.endAudio(); task?.cancel()
    begin()
    if !text.isEmpty { onDone(text) }
  }
}

// MARK: main
// Launched as an .app there is no terminal to print to, so everything goes to macvoice.log.
let exePath = CommandLine.arguments[0]
if exePath.contains(".app/Contents/MacOS") {  // not a pipe: only when launched as a bundle
  let logPath = (exePath as NSString).deletingLastPathComponent + "/../../../macvoice.log"
  freopen(logPath, "a", stdout); freopen(logPath, "a", stderr); setvbuf(stdout, nil, _IOLBF, 0)
}
guard let apiKey = loadKey() else { print("No API key: set TYPESAFE_API_KEY or put it in .env"); exit(1) }
let jev = Jev(key: apiKey), apps = installedApps()
if !demo && !AXIsProcessTrusted() && !noScreen {
  print("Accessibility is not granted to this terminal. Run once with prompt: System Settings > Privacy & Security > Accessibility > enable your terminal app, then re-run.")
  if snapOnly || live { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary); exit(1) }
}
if tabList {
  Task {
    print("allBrowserTabs() -> \(allBrowserTabs().count) tabs")
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      guard let n = app.localizedName, scriptableBrowsers.contains(n) else { continue }
      let bid = browserBundles[n] ?? "?"
      let ok = canAutomate(bid)
      let t = ok ? browserTabs(n) : []
      print("\(n) [\(bid)] automation=\(ok ? "yes" : "NO") tabs=\(t.count)")
      for x in t.prefix(3) { print("    \(x.window):\(x.index)  \(x.title.prefix(50))") }
    }
    exit(0)
  }
} else if menuList {
  Task {
    try? await Task.sleep(nanoseconds: UInt64(max(delaySec, 0) * 1e9))
    let s = prepareScreen()
    print("\(s.app): \(s.menus.count) menu commands")
    for c in s.menus { print("  \(c.path)\(c.shortcut.isEmpty ? "" : "   \(c.shortcut)")") }
    exit(0)
  }
} else if snapOnly {
  Task {
    try? await Task.sleep(nanoseconds: UInt64(max(delaySec, 0) * 1e9))
    let t = Date(), s = prepareScreen()
    print("\(s.app) (\(s.bundle)): \(s.els.count) elements in \(ms(t)) ms, window \(Int(s.window.width))x\(Int(s.window.height))")
    for e in s.els { print("  \(e.id) \(e.role): \(e.label)") }
    exit(0)
  }
} else if textMode {
  Task {
    await jev.warm()
    let d = delaySec >= 0 ? delaySec : (demo ? 0 : 3)
    func one(_ line: String) async {
      if d > 0 { print("  (switch to the target app: \(Int(d)) s)"); try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
      await handle(line, snap: nil, voice: false, jev: jev, apps: apps)
    }
    if let t = textCmd, !t.isEmpty { await one(t); exit(0) }
    print(demo ? "demo screen: Cancel, Submit, Save draft, Pricing, Docs, Search, Remember me, Sign in, File, Edit, Delete account, Contact sales. Type commands; Ctrl-D quits." : "type commands; Ctrl-D quits.")
    while let l = readLine() { if !l.isEmpty { await one(l) } }
    exit(0)
  }
}
let prefs = UserDefaults.standard
var micLevel: Float = 0
var muted = false
var hotkey: Hotkey?
var island: NotchIsland?
var statusBar: StatusBar?
func ui(_ st: UIState) { island?.set(st) }

// These two MUST be globals. Declared inside the block below, the Listener was released as soon
// as startup finished; its audio tap and timer hold weak references, so the microphone callback
// silently became a no-op and nothing was ever transcribed.
var snapTask: Task<Screen, Never>?
var listener: Listener?
if !snapOnly && !textMode {
  Task { await jev.warm() }
  Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { _ in Task { await jev.warm() } }  // keep the connection open
  listener = Listener(
    onStart: { ui(.listening("")); snapTask = Task.detached { prepareScreen() } },  // read the screen while you are still talking
    onDone: { text in let s = snapTask; snapTask = nil; Task { await handle(text, snap: s, voice: true, jev: jev, apps: apps) } })
  print(live ? "LIVE: actions will run." : "DRY-RUN: nothing will be done. Add --live to act.")
  listener?.run()
  // A visible hello, so you can see the island exists before saying anything.
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    ui(.ok(live ? "macvoice ready — live" : "macvoice ready — dry-run"))
  }
}
if !snapOnly && !textMode {
  let nsApp = NSApplication.shared
  nsApp.setActivationPolicy(.accessory)  // no dock icon, never steals focus
  island = NotchIsland()
  statusBar = StatusBar(
    live: live, target: targetApp,
    onToggleLive: {
      live.toggle(); prefs.set(live, forKey: "live")
      print(live ? "→ LIVE" : "→ dry-run")
      ui(live ? .warn("live — actions will run") : .ok("dry-run"))
      return live
    },
    onToggleMute: {
      muted.toggle()
      print(muted ? "→ muted" : "→ listening")
      ui(muted ? .warn("muted") : .ok("listening"))
      return muted
    },
    onQuit: { print("quit from menu bar"); NSApplication.shared.terminate(nil) })
  primeAutomation()   // one-time consent prompts, so every browser's tabs are visible
  hotkey = Hotkey {
    muted.toggle()
    statusBar?.setMuted(muted)
    ui(muted ? .warn("muted") : .ok("listening"))
  }
  nsApp.run()
} else {
  dispatchMain()
}

// Spans are cut twice (once to build the question, once to read the answer); keep them identical.
func spansFor(_ text: String) -> [String] { searchSpans(text) }

/// With 31 open tabs a Choice spreads probability so thin the right tab scored 0.10. Narrow the
/// field in code first — word overlap is enough — and let Jev choose among plausible ones.
/// Indices stay the originals so the executor still finds the right tab.
func shortlistTabs(_ tabs: [Tab], _ utterance: String, keep: Int = 12) -> [Int] {
  let stop: Set<String> = ["go", "to", "the", "tab", "switch", "open", "my", "a", "in", "on", "that", "show", "me", "please"]
  let words = utterance.lowercased().split{ !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stop.contains($0) && $0.count > 1 }
  guard !words.isEmpty else { return Array(tabs.indices.prefix(keep)) }
  let scored = tabs.indices.map { i -> (Int, Int) in
    let title = tabs[i].title.lowercased()
    return (i, words.reduce(0) { $0 + (title.contains($1) ? $1.count : 0) })
  }
  let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
  if hits.isEmpty { return Array(tabs.indices.prefix(keep)) }
  // keep the matches, then pad with the first few tabs so "none" stays a fair option
  var out = hits.prefix(keep).map(\.0)
  for i in tabs.indices where out.count < keep && !out.contains(i) { out.append(i) }
  return out
}
