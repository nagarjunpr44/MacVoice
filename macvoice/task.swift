// Multi-step goals: "open youtube in chrome and play the Avengers Doomsday trailer".
//
// One utterance, a loop of observations. Each step re-reads the screen and asks Jev ONE request:
// which operation, and which element. Structure borrowed from browser-use/jev-ultrafast, but driven
// by the Accessibility tree instead of a browser, so it works in any app rather than only the web.
//
// Nothing is generated: the text to type is a span cut from what you said, and every target is an
// element the code observed this step. The model cannot name a button that is not on screen.
import AppKit

struct Step { let op: String; let detail: String }

let taskOps: [String: String] = [
  "click": "Click a control on screen to move the goal forward — a link, button, result, video, field or tab",
  "type_text": "Type the text the goal calls for into the field that is already focused",
  "press_enter": "Press Return to submit what was just typed",
  "scroll_down": "Scroll down to bring more of the page into view",
  "wait": "Nothing useful is on screen yet because the app or page is still loading",
  "done": "The goal has been achieved — the thing asked for is now open, playing or shown",
  "blocked": "The goal cannot be achieved from here, or would need something unsafe",
]

/// Runs a goal to completion. Returns a short outcome for the island.
func runTask(goal: String, jev: Jev, apps: [String: URL], maxSteps: Int = 8,
             live: Bool, onStep: @escaping (String) -> Void) async -> String {
  var history: [Step] = []
  var typedAlready = false
  var lastClicked = ""
  var lastSignature = ""
  var waits = 0
  var lastFieldIdx = -1

  for step in 1...maxSteps {
    let tObs = Date()
    // Try the DOM FIRST and skip the AX walk entirely when it works. Doing the walk and then the
    // DOM read meant still paying the ~2 s we were trying to avoid.
    let frontName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    let dom = domUsable(frontName) ? domRead(frontName) : []
    let usingDom = !dom.isEmpty
    let screen = usingDom
      ? Screen(app: frontName, bundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
               els: [], window: .zero, electron: false)
      : prepareElementsOnly()
    let items: [(id: String, role: String, label: String)] = usingDom
      ? dom.map { ("d\($0.idx)", $0.role, $0.label) }
      : screen.els.prefix(120).map { ($0.id, $0.role, $0.label) }
    guard !items.isEmpty else {
      onStep("waiting for \(screen.app)…")
      try? await Task.sleep(nanoseconds: 700_000_000)
      continue
    }

    // Candidate text to type, cut from the goal by code. Jev only picks which span.
    let spans = spansFor(goal)
    // A signature of what is on screen, so a step that changed nothing is detectable in code.
    let signature = items.prefix(25).map(\.label).joined(separator: "|")
    let unchanged = signature == lastSignature
    lastSignature = signature

    var q: [String: Any] = [
      // Asked BEFORE the operation: the loop kept re-clicking a video that was already playing
      // because nothing ever told it the goal was met.
      "already_done": ["type": "noul",
                       "instructions": "The goal is \"\(goal)\". Has it ALREADY been carried out, judging by `on_screen`? Answer yes only if the end result is actually present — for example the video itself is open on its own page with its controls, or the requested item is genuinely displayed. Text that merely mentions or matches the goal, such as a search box containing those words, a search-results listing, or a tab title, is NOT enough and means no.",
                       "criteria": ["true": "The end result is on screen now", "false": "Only search results, matching text, or a partially finished attempt"]],
      "operation": ["type": "choice",
                    "instructions": "You are carrying out this goal step by step on a Mac: \"\(goal)\". " +
                                    "So far: \(history.isEmpty ? "nothing yet" : history.map { "\($0.op) \($0.detail)" }.joined(separator: "; ")). " +
                                    "The screen now shows \(screen.app). What is the single next operation?",
                    "criteria": taskOps],
    ]
    var t: [String: Any] = ["none": "No element is the right target"]
    for e in items { t[e.id] = "\(e.role): \(e.label)" }
    q["click_target"] = ["type": "choice",
                         "instructions": "If the next operation is a click, which element should be clicked to advance the goal \"\(goal)\"?",
                         "criteria": t]
    q["field_target"] = ["type": "choice",
                         "instructions": "If text must be typed, which field or search box should receive it for the goal \"\(goal)\"?",
                         "criteria": t]
    if !spans.isEmpty {
      var sp: [String: Any] = [:]
      for (i, v) in spans.enumerated() { sp["s\(i)"] = "the text: \(v)" }
      q["type_span"] = ["type": "choice",
                        "instructions": "If text must be typed for the goal \"\(goal)\", which of these is exactly the text to type — the search terms or value only, without words like 'play', 'search for' or the site name?",
                        "criteria": sp]
    }

    let ans: Answers
    // The screen MUST be in the state: "has the goal been achieved?" was being asked with no view
    // of what is on screen, so it could never answer yes and the loop always ran out of steps.
    let state: [String: Any] = [
      "goal": goal,
      "app": screen.app,
      "step": step,
      "on_screen": items.prefix(60).map { "\($0.role): \($0.label)" },
      "done_so_far": history.map { "\($0.op) \($0.detail)" },
    ]
    do { (ans, _) = try await jev.ask(state: state, questions: q) }
    catch { return "step \(step) failed: \(error.localizedDescription)" }

    if ans.noul("already_done") >= 0.80, step > 2, !(unchanged && lastClicked != "") {
      return "done in \(step - 1) step\(step == 2 ? "" : "s")"
    }
    guard var (op, opConf) = pick(ans, "operation", 0.40, 0.50).map({ ($0.0, $0.1) }) else {
      return "unsure what to do next (step \(step))"
    }
    // Clicking the same thing again on an unchanged screen is a loop, not progress.
    // Jev kept answering "wait" after a page had already loaded, and the accumulating wait history
    // reinforced it. Two waits is enough; after that, make it commit to a target.
    if op == "wait" { waits += 1 } else { waits = 0 }
    if op == "wait", waits > 2 { op = "click" }
    if op == "click", unchanged,
       let (tid, _) = pick(ans, "click_target", 0.30, 0.45), tid != "none",
       items.first(where: { $0.id == tid })?.label == lastClicked {
      op = history.count >= 2 ? "done" : "wait"
    }

    switch op {
    case "done":    return "done in \(step - 1) step\(step == 2 ? "" : "s")"
    case "blocked": return "cannot do that from here"
    case "wait":
      onStep("waiting… (\(items.count) elements)")
      try? await Task.sleep(nanoseconds: 900_000_000)
      history.append(Step(op: "wait", detail: ""))

    case "scroll_down":
      onStep("scrolling")
      if live { scroll("down", screen) }
      history.append(Step(op: "scrolled", detail: ""))

    case "press_enter":
      onStep("press enter")
      if live {
        if usingDom, lastFieldIdx >= 0 { _ = domSubmit(frontName, lastFieldIdx) } else { pressKey("enter") }
      }
      history.append(Step(op: "pressed", detail: "enter"))
      try? await Task.sleep(nanoseconds: 1_400_000_000)   // a submitted search needs longer to render

    case "type_text":
      guard !typedAlready,
            let (sid, _) = pick(ans, "type_span", 0.30, 0.40), let si = Int(sid.dropFirst()), si < spans.count else {
        history.append(Step(op: "skipped", detail: "type")); break
      }
      let payload = spans[si]
      if let (fid, _) = pick(ans, "field_target", 0.35, 0.45), fid != "none",
         let f = items.first(where: { $0.id == fid }) {
        onStep("typing into \(f.label)")
        if live {
          if usingDom, let i = Int(f.id.dropFirst()) {
            lastFieldIdx = i
            _ = domFill(frontName, i, payload)
          } else if let el = screen.els.first(where: { $0.id == f.id }) {
            click(el, screen); usleep(250_000); typeText(payload)
          }
        }
      } else {
        onStep("typing")
        if live { typeText(payload) }
      }
      typedAlready = true
      history.append(Step(op: "typed", detail: payload))

    case "click":
      guard let (tid, tc) = pick(ans, "click_target", 0.30, 0.45), tid != "none",
            let el = items.first(where: { $0.id == tid }) else {
        history.append(Step(op: "no target", detail: ""))
        try? await Task.sleep(nanoseconds: 500_000_000)
        break
      }
      // The policy applies to every step, not just the spoken command.
      if case .block(let why) = judge(subject: el.label, utterance: goal, appName: screen.app) {
        return "stopped: \(why)"
      }
      onStep("click \(el.label)  [\(items.count) \(usingDom ? "dom" : "ax") els, \(ms(tObs)) ms]")
      if live {
        if usingDom {
          // Read via the DOM (fast), but CLICK via Accessibility (proven). Synthetic DOM clicks,
          // href navigation and real events at DOM coordinates all failed to open a YouTube
          // result, while the AX click reached the watch page every time. The AX walk is paid
          // only on click steps, not on every observation.
          let axScreen = prepareElementsOnly()
          if let match = axScreen.els.first(where: { $0.label == el.label })
              ?? axScreen.els.first(where: { el.label.hasPrefix($0.label) && $0.label.count > 8 }) {
            click(match, axScreen)
          } else if let i = Int(el.id.dropFirst()), let d = dom.first(where: { $0.idx == i }),
                    let o = domViewportOrigin(frontName) {
            _ = domClickReal(frontName, d, origin: o)
          }
        }
        else if let axEl = screen.els.first(where: { $0.id == el.id }) { click(axEl, screen) }
      }
      lastClicked = el.label
      history.append(Step(op: "clicked", detail: el.label))
      _ = tc

    default:
      history.append(Step(op: op, detail: ""))
    }
    _ = opConf
    try? await Task.sleep(nanoseconds: 900_000_000)   // let the UI catch up before observing again
  }
  return "gave up after \(maxSteps) steps"
}
