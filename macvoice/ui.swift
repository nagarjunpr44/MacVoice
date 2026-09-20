// Notch island + menu bar item. Declarations only — top-level code lives in main.swift.
import AppKit
import ServiceManagement

enum UIState {
  case idle, listening(String), thinking(String), ok(String), warn(String), fail(String)
  var text: String {
    switch self {
    case .idle: return ""
    case .listening(let s): return s.isEmpty ? "listening…" : s
    case .thinking(let s), .ok(let s), .warn(let s), .fail(let s): return s
    }
  }
  var tint: NSColor {
    switch self {
    case .idle, .listening: return NSColor(calibratedRed: 0.42, green: 0.78, blue: 1.0, alpha: 1)
    case .thinking: return NSColor(calibratedRed: 0.72, green: 0.66, blue: 1.0, alpha: 1)
    case .ok: return NSColor(calibratedRed: 0.35, green: 0.88, blue: 0.55, alpha: 1)
    case .warn: return NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.28, alpha: 1)
    case .fail: return NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.42, alpha: 1)
    }
  }
  var glyph: String {
    switch self {
    case .idle: return ""
    case .listening: return "●"
    case .thinking: return "◐"
    case .ok: return "✓"
    case .warn: return "!"
    case .fail: return "✕"
    }
  }
  var holdSeconds: Double {
    switch self {
    case .idle, .listening, .thinking: return 0  // stay until replaced
    case .ok: return 1.6
    case .warn: return 4.0
    case .fail: return 2.6
    }
  }
}

/// A pill that grows out of the notch: live waveform while you speak, result when it acts.
/// Audio-reactive rather than a synthetic wobble — the bars are the real mic level.
final class NotchIsland {
  private let panel: NSPanel
  private let pill = NSView()
  private let wave = WaveView()
  private let glyph = NSTextField(labelWithString: "")
  private let label = NSTextField(labelWithString: "")
  private let screen: NSScreen
  private let notchW: CGFloat, notchH: CGFloat
  private var collapseWork: DispatchWorkItem?
  private var state: UIState = .idle

  init() {
    screen = NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil } ?? NSScreen.main ?? NSScreen.screens[0]
    if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
      notchW = screen.frame.width - l.width - r.width
      notchH = max(screen.safeAreaInsets.top, 24)
    } else {
      notchW = 150; notchH = 26
    }
    panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .init(Int(CGWindowLevelForKey(.maximumWindow)))
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false

    pill.wantsLayer = true
    if let l = pill.layer {
      l.backgroundColor = NSColor.black.cgColor
      l.cornerRadius = 14
      l.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
      l.cornerCurve = .continuous
      l.shadowColor = NSColor.black.cgColor       // lifts the pill off a light wallpaper
      l.shadowOpacity = 0.5
      l.shadowRadius = 10
      l.shadowOffset = CGSize(width: 0, height: -2)
    }
    glyph.font = .systemFont(ofSize: 12, weight: .bold)
    glyph.alignment = .center
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = NSColor(white: 0.97, alpha: 1)
    label.lineBreakMode = .byTruncatingTail
    label.cell?.usesSingleLineMode = true
    for v in [wave, glyph, label] as [NSView] { pill.addSubview(v) }

    panel.contentView = { let v = NSView(); v.addSubview(pill); return v }()
    place(animated: false)
    panel.alphaValue = 0
  }

  /// The pill flanks the cutout: waveform to its LEFT, text to its RIGHT, nothing underneath.
  /// The old layout measured from the pill's left edge, which put the text under the camera.
  private var leftW: CGFloat = 46, rightW: CGFloat = 120

  private func place(animated: Bool) {
    let f = screen.frame
    let w = leftW + notchW + rightW, h = notchH
    // Anchor on the cutout, which is centred on the screen, so the two regions can differ in width.
    let rect = NSRect(x: f.midX - notchW / 2 - leftW, y: f.maxY - h, width: w, height: h)
    if animated {
      NSAnimationContext.runAnimationGroup { c in
        c.duration = 0.32
        c.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 1.25, 0.4, 1)  // spring overshoot
        panel.animator().setFrame(rect, display: true)
        panel.animator().alphaValue = 1
      }
    } else {
      panel.setFrame(rect, display: false)
    }
    pill.frame = NSRect(x: 0, y: 0, width: w, height: h)
    let midY = (h - 18) / 2
    wave.frame = NSRect(x: leftW - 40, y: midY, width: 34, height: 18)
    glyph.frame = NSRect(x: leftW - 28, y: midY, width: 18, height: 18)
    label.frame = NSRect(x: leftW + notchW + 10, y: midY, width: max(rightW - 20, 10), height: 18)
  }

  private func textWidth(_ s: String) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: label.font!]).width
  }

  func set(_ new: UIState) { DispatchQueue.main.async { self.apply(new) } }

  private func apply(_ new: UIState) {
    collapseWork?.cancel()
    state = new
    if case .idle = new {
      wave.running = false
      NSAnimationContext.runAnimationGroup { c in
        c.duration = 0.24
        c.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().alphaValue = 0
        let f = screen.frame
        panel.animator().setFrame(NSRect(x: f.midX - notchW / 2, y: f.maxY - notchH, width: notchW, height: notchH), display: true)
      } completionHandler: { [weak self] in
        guard let self, case .idle = self.state else { return }
        self.panel.orderOut(nil)
      }
      return
    }
    var listening = false
    if case .listening = new { listening = true }
    wave.isHidden = !listening
    wave.tint = new.tint
    wave.running = listening
    glyph.isHidden = listening
    glyph.stringValue = new.glyph
    glyph.textColor = new.tint
    label.stringValue = new.text
    label.textColor = listening ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.97, alpha: 1)

    if !panel.isVisible {
      leftW = 46; rightW = 0
      place(animated: false)
      panel.alphaValue = 0
      panel.orderFrontRegardless()
    }
    leftW = 46
    rightW = min(max(textWidth(new.text) + 26, 90), screen.frame.width / 2 - notchW / 2 - 30)
    place(animated: true)

    if new.holdSeconds > 0 {
      let work = DispatchWorkItem { [weak self] in self?.apply(.idle) }
      collapseWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + new.holdSeconds, execute: work)
    }
  }
}

/// Five bars driven by the real microphone level, with a gentle idle breathe so it never looks dead.
final class WaveView: NSView {
  var tint: NSColor = .systemBlue { didSet { needsDisplay = true } }
  var running = false {
    didSet {
      guard running != oldValue else { return }
      running ? start() : timer?.invalidate()
      if !running { timer = nil }
    }
  }
  private var timer: Timer?
  private var levels: [CGFloat] = Array(repeating: 0.12, count: 5)
  private var phase: CGFloat = 0

  private func start() {
    timer?.invalidate()
    let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }
  private func step() {
    phase += 0.28
    let level = CGFloat(micLevel)
    for i in levels.indices {
      // each bar reacts to the same level with its own offset, so it reads as a waveform
      let wobble = (sin(phase + CGFloat(i) * 0.9) + 1) / 2
      let target = max(0.12, min(1, level * (0.55 + 0.75 * wobble)))
      levels[i] += (target - levels[i]) * 0.45          // smoothing, no jitter
    }
    needsDisplay = true
  }
  override func draw(_ dirty: NSRect) {
    let n = levels.count, w: CGFloat = 3, gap: CGFloat = 4
    let total = CGFloat(n) * w + CGFloat(n - 1) * gap
    var x = (bounds.width - total) / 2
    for l in levels {
      let h = max(3, bounds.height * l)
      let r = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
      tint.withAlphaComponent(0.55 + 0.45 * l).setFill()
      NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
      x += w + gap
    }
  }
}

/// Menu bar item: the whole app's controls, so it never needs a terminal.
/// ◉ live · ◎ dry-run · ◌ muted.
final class StatusBar {
  private let item = NSStatusItem.itemFactory()
  private let onQuit: () -> Void
  private let onToggleLive: () -> Bool
  private let onToggleMute: () -> Bool
  private var liveItem: NSMenuItem?, muteItem: NSMenuItem?, loginItem: NSMenuItem?
  private var live = false, muted = false

  init(live: Bool, target: String?, onToggleLive: @escaping () -> Bool,
       onToggleMute: @escaping () -> Bool, onQuit: @escaping () -> Void) {
    self.onQuit = onQuit
    self.onToggleLive = onToggleLive
    self.onToggleMute = onToggleMute
    item.button?.font = .systemFont(ofSize: 13, weight: .semibold)
    item.button?.toolTip = "macvoice"
    let menu = NSMenu()
    let head = NSMenuItem(title: target.map { "macvoice → \($0)" } ?? "macvoice", action: nil, keyEquivalent: "")
    head.isEnabled = false
    menu.addItem(head)
    menu.addItem(.separator())

    let m = NSMenuItem(title: "", action: #selector(toggleMute), keyEquivalent: "")
    m.target = self; menu.addItem(m); muteItem = m
    let l = NSMenuItem(title: "", action: #selector(toggleLive), keyEquivalent: "")
    l.target = self; menu.addItem(l); liveItem = l
    menu.addItem(.separator())

    let g = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    g.target = self; menu.addItem(g); loginItem = g
    let q = NSMenuItem(title: "Quit macvoice", action: #selector(quit), keyEquivalent: "q")
    q.target = self; menu.addItem(q)
    item.menu = menu
    setLive(live); setMuted(false); refreshLogin()
  }

  func setLive(_ v: Bool) {
    live = v
    liveItem?.title = v ? "Live — actions run (click for dry-run)" : "Dry-run — nothing runs (click to go live)"
    refreshIcon()
  }
  func setMuted(_ v: Bool) {
    muted = v
    muteItem?.title = v ? "Muted — not listening  (⌘M)" : "Listening  (⌘M to mute)"
    refreshIcon()
  }
  private func refreshIcon() { item.button?.title = muted ? "◌" : (live ? "◉" : "◎") }

  private func refreshLogin() { loginItem?.state = LoginItem.enabled ? .on : .off }
  @objc private func toggleLogin() { LoginItem.toggle(); refreshLogin() }
  @objc private func toggleLive() { setLive(onToggleLive()) }
  @objc private func toggleMute() { setMuted(onToggleMute()) }
  @objc private func quit() { onQuit() }
}

/// Launch at login, via the modern API (no login-item plist hacks).
enum LoginItem {
  static var enabled: Bool {
    if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
    return false
  }
  static func toggle() {
    guard #available(macOS 13, *) else { return }
    do { enabled ? try SMAppService.mainApp.unregister() : try SMAppService.mainApp.register() }
    catch { NSLog("login item: \(error)") }
  }
}

/// ⌘M mutes/unmutes from anywhere.
///
/// Uses a CGEventTap rather than NSEvent's global monitor because a monitor only *observes*:
/// ⌘M would still reach the app underneath and minimise its window. A tap can swallow the
/// keystroke, so ⌘M means "mute macvoice" and nothing else. Needs the Accessibility grant,
/// which this app already has.
private var hotkeyAction: (() -> Void)?

final class Hotkey {
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?

  init(keyCode: CGKeyCode = 46, flags: CGEventFlags = .maskCommand, _ action: @escaping () -> Void) {
    hotkeyAction = action
    let cb: CGEventTapCallBack = { proxy, type, event, _ in
      // The tap is disabled by the system if it ever times out; re-arm instead of dying silently.
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = activeHotkeyTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
      }
      guard type == .keyDown else { return Unmanaged.passUnretained(event) }
      let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
      let mods = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
      if code == hotkeyCode, mods == hotkeyFlags {
        DispatchQueue.main.async { hotkeyAction?() }
        return nil                       // swallow it: no Minimise Window
      }
      return Unmanaged.passUnretained(event)
    }
    hotkeyCode = keyCode
    hotkeyFlags = flags
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                    options: .defaultTap, eventsOfInterest: mask,
                                    callback: cb, userInfo: nil) else {
      NSLog("hotkey: could not create event tap (Accessibility not granted?)")
      return
    }
    tap = t
    activeHotkeyTap = t
    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
  }
}

private var activeHotkeyTap: CFMachPort?
private var hotkeyCode: CGKeyCode = 46          // 46 = M
private var hotkeyFlags: CGEventFlags = .maskCommand

extension NSStatusItem {
  static func itemFactory() -> NSStatusItem { NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
}
