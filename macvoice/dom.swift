// Reading a web page through the DOM instead of the Accessibility tree.
//
// The AX tree sees the same elements (measured: identical table on Google Flights), but a full AX
// read of a heavy page costs 1.8-3.3 s, while the DOM answers in milliseconds. In a loop that
// re-observes after every step, that difference is the whole experience.
//
// This uses the AppleScript bridge macvoice already has for tabs — no browser debugging port, no
// second process, no extra API key. Requires Chrome/Brave: View > Developer > Allow JavaScript
// from Apple Events.
import AppKit

struct DomEl {
  let idx: Int
  let role: String
  let label: String
  let rect: CGRect        // viewport coordinates
}

/// Marks each candidate with an index and returns "idx\u{1}role\u{1}label" rows. The index is an
/// attribute on the live node, so a later click refers to the element we actually observed rather
/// than re-running a selector that may match something else.
private let collectJS = """
(function(){
  var sel = 'a,button,input,textarea,select,summary,[role=button],[role=link],[role=tab],[role=checkbox],[role=menuitem],[role=option],[contenteditable=true]';
  var out = [], n = 0;
  var nodes = document.querySelectorAll(sel);
  for (var i = 0; i < nodes.length && out.length < 120; i++) {
    var e = nodes[i];
    var r = e.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) continue;
    if (r.bottom < 0 || r.top > innerHeight + 600) continue;
    var st = getComputedStyle(e);
    if (st.visibility === 'hidden' || st.display === 'none' || st.opacity === '0') continue;
    if (e.disabled) continue;
    if (e.type === 'password') continue;
    var lab = e.getAttribute('aria-label') || e.getAttribute('placeholder') || e.getAttribute('title')
           || (e.innerText || '').trim() || e.value || e.getAttribute('alt') || e.name || '';
    lab = String(lab).replace(/\\s+/g, ' ').trim().slice(0, 70);
    if (!lab) continue;
    var role = e.getAttribute('role') || e.tagName.toLowerCase();
    if (role === 'input') role = (e.type || 'text') + ' field';
    if (role === 'a') role = 'link';
    e.setAttribute('data-mv', String(n));
    out.push(n + '\\u0001' + role + '\\u0001' + lab + '\\u0001' +
             Math.round(r.left) + ',' + Math.round(r.top) + ',' + Math.round(r.width) + ',' + Math.round(r.height));
    n++;
  }
  return out.join('\\u0002');
})()
"""

private func js(_ app: String, _ script: String, seconds: Double = 3) -> String? {
  // The script is embedded in an AppleScript string literal, so its quotes and backslashes escape.
  let escaped = script
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: " ")
  let src = """
  tell application "\(app)"
    tell active tab of window 1 to execute javascript "\(escaped)"
  end tell
  """
  var result: String??
  let sem = DispatchSemaphore(value: 0)
  DispatchQueue.global(qos: .userInitiated).async {
    var err: NSDictionary?
    let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err {
      // -2700 with "turned off" means the Chrome setting is not enabled; everything else is a page error.
      NSLog("dom js: \(err)")
      result = .some(nil)
    } else { result = .some(out?.stringValue) }
    sem.signal()
  }
  if sem.wait(timeout: .now() + seconds) == .timedOut { return nil }
  return result ?? nil
}

/// True when this app is a browser we can read the DOM of right now.
func domAvailable(_ app: String) -> Bool {
  guard scriptableBrowsers.contains(app), app != "Safari" else { return false }
  return js(app, "1") == "1"
}

func domRead(_ app: String) -> [DomEl] {
  guard let raw = js(app, collectJS), !raw.isEmpty else { return [] }
  return raw.components(separatedBy: "\u{2}").compactMap { row in
    let p = row.components(separatedBy: "\u{1}")
    guard p.count == 4, let i = Int(p[0]) else { return nil }
    let n = p[3].split(separator: ",").compactMap { Double($0) }
    guard n.count == 4 else { return nil }
    return DomEl(idx: i, role: p[1], label: p[2], rect: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))
  }
}

/// Clicks the element we indexed this observation.
func domClick(_ app: String, _ idx: Int) -> Bool {
  let script = """
  (function(){
    var e = document.querySelector('[data-mv="\(idx)"]');
    if (!e) return 'gone';
    e.scrollIntoView({block:'center'});
    // A plain .click() is swallowed by sites that route clicks in JS (YouTube result links do
    // nothing), so when the element really is a link, navigate to its href instead.
    var a = e.closest('a[href]');
    if (a && a.href && !a.href.startsWith('javascript:')) { location.href = a.href; return 'ok nav'; }
    e.click();
    return 'ok click';
  })()
  """
  guard let out = js(app, script), out.hasPrefix("ok") else { return false }
  return true
}

/// Types into a field: focus it, set the value, and fire the events frameworks listen for.
func domFill(_ app: String, _ idx: Int, _ text: String) -> Bool {
  let safe = text.replacingOccurrences(of: "'", with: "\\'")
  let script = """
  (function(){
    var e = document.querySelector('[data-mv="\(idx)"]');
    if (!e) return 'gone';
    e.focus();
    var v = '\(safe)';
    if (e.isContentEditable) { e.textContent = v; }
    else {
      var setter = Object.getOwnPropertyDescriptor(e.constructor.prototype, 'value');
      if (setter && setter.set) { setter.set.call(e, v); } else { e.value = v; }
    }
    e.dispatchEvent(new Event('input', {bubbles:true}));
    e.dispatchEvent(new Event('change', {bubbles:true}));
    return 'ok';
  })()
  """
  return js(app, script) == "ok"
}

/// Submits the form/search box we just filled, without relying on a visible button.
func domSubmit(_ app: String, _ idx: Int) -> Bool {
  let script = """
  (function(){
    var e = document.querySelector('[data-mv="\(idx)"]');
    if (!e) return 'gone';
    e.focus();
    ['keydown','keypress','keyup'].forEach(function(t){
      e.dispatchEvent(new KeyboardEvent(t, {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true}));
    });
    if (e.form && e.form.requestSubmit) { try { e.form.requestSubmit(); } catch(x) {} }
    return 'ok';
  })()
  """
  return js(app, script) == "ok"
}

/// domAvailable costs a round trip, so remember the answer per app for a while.
private var domOK: [String: (at: Date, ok: Bool)] = [:]
func domUsable(_ app: String) -> Bool {
  if let c = domOK[app], Date().timeIntervalSince(c.at) < 60 { return c.ok }
  let ok = domAvailable(app)
  domOK[app] = (Date(), ok)
  return ok
}


/// Where the page's viewport sits on screen. Chrome's toolbar means the viewport starts below the
/// window origin, so a viewport point needs this offset before it can be clicked for real.
func domViewportOrigin(_ app: String) -> CGPoint? {
  guard let out = js(app, "window.screenX + ',' + window.screenY + ',' + (window.outerHeight - window.innerHeight)"),
        case let n = out.split(separator: ",").compactMap({ Double($0) }), n.count == 3 else { return nil }
  return CGPoint(x: n[0], y: n[1] + n[2])
}

/// Clicks a DOM element with a REAL mouse event at its own coordinates.
/// Synthetic .click() and href navigation both work on simple pages and both fail on sites that
/// route interaction through JS (YouTube's results are the case that exposed it). A real event at
/// the right pixel is what the page would see from a person, so it works everywhere.
func domClickReal(_ app: String, _ el: DomEl, origin: CGPoint) -> Bool {
  _ = js(app, "(function(){var e=document.querySelector('[data-mv=\"\(el.idx)\"]'); if(e) e.scrollIntoView({block:'center'}); return 'ok';})()")
  usleep(220_000)
  // Re-read the rect after scrolling; it has almost certainly moved.
  guard let out = js(app, "(function(){var e=document.querySelector('[data-mv=\"\(el.idx)\"]'); if(!e) return ''; var r=e.getBoundingClientRect(); return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()"),
        case let c = out.split(separator: ",").compactMap({ Double($0) }), c.count == 2 else { return false }
  cgClick(CGPoint(x: origin.x + c[0], y: origin.y + c[1]))
  return true
}
