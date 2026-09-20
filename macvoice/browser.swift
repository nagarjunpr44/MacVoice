// Browser tabs and search, via AppleScript. The Accessibility tree only shows the FRONT tab of the
// FRONT window; AppleScript sees every tab of every window, which is what "go to my wikipedia tab" needs.
import AppKit

struct Tab { let window: Int; let index: Int; let title: String; let app: String }

let scriptableBrowsers = ["Safari", "Google Chrome", "Brave Browser", "Microsoft Edge", "Arc", "Vivaldi", "Opera"]

/// Automation consent, checked WITHOUT prompting. A blocking prompt inside the snapshot path
/// froze the whole app until the dialog was answered.
func canAutomate(_ bundleId: String) -> Bool {
  guard var target = NSAppleEventDescriptor(bundleIdentifier: bundleId).aeDesc?.pointee else { return false }
  defer { AEDisposeDesc(&target) }
  return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) == noErr
}

let browserBundles = ["Safari": "com.apple.Safari", "Google Chrome": "com.google.Chrome",
                              "Brave Browser": "com.brave.Browser", "Microsoft Edge": "com.microsoft.edgemac",
                              "Arc": "company.thebrowser.Browser", "Vivaldi": "com.vivaldi.Vivaldi",
                              "Opera": "com.operasoftware.Opera"]

func run(_ source: String, seconds: Double = 5) -> String? {
  // executeAndReturnError can block far past any AppleScript `with timeout`, so cap it here too.
  var result: String??
  let sem = DispatchSemaphore(value: 0)
  DispatchQueue.global(qos: .userInitiated).async {
    var err: NSDictionary?
    let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
    if let err { NSLog("applescript: \(err)"); result = .some(nil) } else { result = .some(out?.stringValue) }
    sem.signal()
  }
  if sem.wait(timeout: .now() + seconds) == .timedOut { NSLog("applescript timed out"); return nil }
  return result ?? nil
}

/// Chrome-family and Safari use different vocabulary for the same idea.
private func listSource(_ app: String) -> String {
  let titleExpr = app == "Safari" ? "name of t" : "title of t"
  return """
  set out to ""
  with timeout of 2 seconds
  tell application "\(app)"
    set wi to 0
    repeat with w in windows
      set wi to wi + 1
      set ti to 0
      repeat with t in tabs of w
        set ti to ti + 1
        set out to out & wi & "|" & ti & "|" & (\(titleExpr)) & linefeed
      end repeat
    end repeat
  end tell
  end timeout
  return out
  """
}

func browserTabs(_ app: String, limit: Int = 60) -> [Tab] {
  guard scriptableBrowsers.contains(app), let bid = browserBundles[app], canAutomate(bid),
        let raw = run(listSource(app)) else { return [] }
  var out: [Tab] = []
  for line in raw.split(separator: "\n") {
    let p = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
    guard p.count == 3, let w = Int(p[0]), let i = Int(p[1]) else { continue }
    let t = p[2].trimmingCharacters(in: .whitespaces)
    if t.isEmpty { continue }
    out.append(Tab(window: w, index: i, title: String(t.prefix(70)), app: app))
    if out.count >= limit { break }
  }
  return out
}

func focusTab(_ t: Tab) -> Bool {
  let src: String
  if t.app == "Safari" {
    src = """
    tell application "Safari"
      set current tab of window \(t.window) to tab \(t.index) of window \(t.window)
      set index of window \(t.window) to 1
      activate
    end tell
    return "ok"
    """
  } else {
    src = """
    tell application "\(t.app)"
      set active tab index of window \(t.window) to \(t.index)
      set index of window \(t.window) to 1
      activate
    end tell
    return "ok"
    """
  }
  return run(src) != nil
}

/// Opens a query in a new tab. The query text comes from the transcript verbatim — Jev only ever
/// picks which span it is, it never writes text.
func webSearch(_ query: String, engine: String, in app: String) -> Bool {
  guard var c = URLComponents(string: engineBase(engine)) else { return false }
  c.queryItems = [URLQueryItem(name: engineParam(engine), value: query)]
  guard let url = c.url else { return false }
  let target = scriptableBrowsers.contains(app) ? app : "Safari"
  let src = """
  tell application "\(target)"
    activate
    \(target == "Safari" ? "tell window 1 to set current tab to (make new tab with properties {URL:\"\(url.absoluteString)\"})"
                         : "tell window 1 to make new tab with properties {URL:\"\(url.absoluteString)\"}")
  end tell
  return "ok"
  """
  if run(src) != nil { return true }
  return NSWorkspace.shared.open(url)   // no window open yet, or a non-scriptable browser
}

func engineBase(_ e: String) -> String {
  switch e {
  case "youtube": return "https://www.youtube.com/results"
  case "google_maps": return "https://www.google.com/maps/search/"
  case "github": return "https://github.com/search"
  case "wikipedia": return "https://en.wikipedia.org/w/index.php"
  case "amazon": return "https://www.amazon.com/s"
  case "duckduckgo": return "https://duckduckgo.com/"
  default: return "https://www.google.com/search"
  }
}
func engineParam(_ e: String) -> String {
  switch e {
  case "youtube", "github", "amazon": return e == "amazon" ? "k" : "q"
  case "wikipedia": return "search"
  case "google_maps": return "q"
  default: return "q"
  }
}

/// Candidate spans for the search text, cut by code. Jev picks one; we copy it verbatim.
func searchSpans(_ text: String) -> [String] {
  var out: [String] = []
  let patterns = [
    "(?:search|google|look up|find|youtube)\\s+(?:for\\s+)?(.+)$",
    "(?:search|look)\\s+(?:on|in)\\s+\\S+\\s+(?:for\\s+)?(.+)$",
    "(?:for)\\s+(.+)$",
  ]
  for p in patterns {
    guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { continue }
    let s = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    if !s.isEmpty && !out.contains(s) { out.append(s) }
  }
  // strip a trailing site name: "cats on youtube" -> "cats"
  for s in out {
    if let re = try? NSRegularExpression(pattern: "\\s+(?:on|in)\\s+(?:youtube|google|safari|chrome|brave|wikipedia|github|amazon|maps)$", options: .caseInsensitive) {
      let t = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
      if t != s && !out.contains(t) { out.append(t) }
    }
  }
  if !text.isEmpty && !out.contains(text) { out.append(text) }
  return Array(out.prefix(6))
}


private var tabCache: (at: Date, tabs: [Tab])?

/// Tabs from EVERY running browser, not just the front one — "go to my wikipedia tab" does not care
/// which browser or window it lives in. Cached briefly: each browser costs an Apple event.
func allBrowserTabs(limit: Int = 70) -> [Tab] {
  if let c = tabCache, Date().timeIntervalSince(c.at) < 6 { return c.tabs }
  var out: [Tab] = []
  var partial = false
  for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    guard let name = app.localizedName, scriptableBrowsers.contains(name) else { continue }
    let got = browserTabs(name, limit: limit)
    // A browser we are allowed to script but that returned nothing is a timeout (it is busy being
    // AX-walked), not an empty browser. Caching that hides its tabs for the next 6 seconds.
    if got.isEmpty, let b = browserBundles[name], canAutomate(b) { partial = true }
    out.append(contentsOf: got)
    if out.count >= limit { break }
  }
  let capped = Array(out.prefix(limit))
  if !partial { tabCache = (Date(), capped) }
  return capped
}

/// Browsers that are running but have not been granted Automation yet, so we can say so instead
/// of silently ignoring their tabs.
/// Asks for Automation consent once per browser, at startup, off the hot path. Without this the
/// non-prompting check silently returns false forever and that browser's tabs never appear —
/// which is exactly how Chrome's 26 tabs went missing while Brave's showed up.
func primeAutomation() {
  DispatchQueue.global(qos: .utility).async {
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      guard let n = app.localizedName, scriptableBrowsers.contains(n), let bid = browserBundles[n] else { continue }
      guard var target = NSAppleEventDescriptor(bundleIdentifier: bid).aeDesc?.pointee else { continue }
      let st = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)  // may prompt
      AEDisposeDesc(&target)
      print("  automation \(n): \(st == noErr ? "granted" : (st == -1743 ? "DENIED — enable it in Privacy & Security > Automation" : "err \(st)"))")
    }
    tabCache = nil
  }
}

func browsersNeedingAutomation() -> [String] {
  NSWorkspace.shared.runningApplications.compactMap { app in
    guard app.activationPolicy == .regular, let n = app.localizedName,
          scriptableBrowsers.contains(n), let b = browserBundles[n], !canAutomate(b) else { return nil }
    return n
  }
}

func siteURL(_ s: String) -> String {
  switch s {
  case "youtube": return "https://www.youtube.com"
  case "gmail": return "https://mail.google.com"
  case "github": return "https://github.com"
  case "maps": return "https://www.google.com/maps"
  case "amazon": return "https://www.amazon.com"
  case "wikipedia": return "https://en.wikipedia.org"
  case "twitter": return "https://x.com"
  case "reddit": return "https://www.reddit.com"
  case "linkedin": return "https://www.linkedin.com"
  case "chatgpt": return "https://chatgpt.com"
  case "claude": return "https://claude.ai"
  default: return "https://www.google.com"
  }
}

/// Navigates the FRONT window of a named browser, so a profile opened a step earlier is reused
/// instead of a new window appearing somewhere else.
func openURLIn(_ url: String, browser: String) -> Bool {
  let src = browser == "Safari"
    ? """
      tell application "Safari"
        activate
        if (count of windows) = 0 then make new document
        tell window 1 to set current tab to (make new tab with properties {URL:"\(url)"})
      end tell
      return "ok"
      """
    : """
      tell application "\(browser)"
        activate
        if (count of windows) = 0 then make new window
        tell window 1 to make new tab with properties {URL:"\(url)"}
      end tell
      return "ok"
      """
  if run(src) != nil { return true }
  return NSWorkspace.shared.open(URL(string: url)!)
}
