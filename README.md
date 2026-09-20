# macvoice

Control your Mac by talking to it. Say *"open chrome"*, *"make the text bigger"*, *"go to the wikipedia tab"*, *"play the current video"*, *"put this window on the other screen"* — it clicks, opens,
scrolls, types, runs menu commands and moves windows.

Speech is recognised **on-device**. Each utterance becomes **one** request to
[TypeSafe Jev](https://docs.typesafe.ai), a System One model that returns a typed decision with
probabilities instead of generated text. Jev only ever *chooses* from options this app observed on
your screen — it cannot invent an action, name a button that isn't there, or write text — and your
code decides whether that choice is confident enough to act on.

Typical command: **~300 ms** of model time, about **$0.0002**.

---

## What it can do

| Say | What happens |
| --- | --- |
| "open chrome", "open chrome in work profile" | Launches an app, optionally a specific browser profile |
| "click sign in", "tick remember me" | Clicks any labelled button, link, checkbox or tab on screen |
| "make the text bigger", "open a private window" | Runs the app's own **menu commands** — no shortcut needed |
| "go to the wikipedia tab" | Switches to any open tab, in **any window of any browser** |
| "open youtube", "search youtube for lofi" | Opens a site, or searches the web or a specific site |
| "play the current video", "pause", "next", "volume up" | **Media keys** — work on whatever is playing, in any app |
| "maximize this window", "put this on the other screen" | Window and multi-display management |
| "scroll down", "copy this", "undo", "new tab" | Scrolling and 24 keyboard shortcuts |
| "open chrome on the external display **and** calculator on the built in display" | **Compound commands** — several actions in one sentence |
| "play the Avengers Doomsday trailer" | **Multi-step task** — it works out the steps itself |

Nothing is hardcoded. Tabs, menu commands and on-screen controls are read from your Mac on **every
command**, so a tab you opened a second ago is immediately sayable, and one you closed is gone.

---

## Requirements

- macOS 14+ (the notch UI needs a notched display; everything else works without one)
- Xcode **Command Line Tools** only — no full Xcode
- A TypeSafe API key from [console.typesafe.ai](https://console.typesafe.ai/keys)

## Setup

```sh
echo 'TYPESAFE_API_KEY=sk-...' > .env      # in the repo root; it is gitignored
cd macvoice && ./build.sh
```

Then **double-click `macvoice.app`**, or drag it to your Dock. No terminal needed.

### Permissions

macOS will ask on first run. All are genuinely required:

| Permission | Why | If it doesn't appear |
| --- | --- | --- |
| **Microphone** | To hear you | System Settings → Privacy & Security → Microphone |
| **Speech Recognition** | On-device transcription | …→ Speech Recognition |
| **Accessibility** | Read on-screen controls, and click/type | …→ Accessibility → **+** → add `macvoice.app` |
| **Automation** | Read browser tabs, open sites | …→ Automation → macvoice |

`./grant.sh` resets the Accessibility entry and opens the right pane if it gets stuck.

**Optional, for faster web pages:** Chrome/Brave → View → Developer → **Allow JavaScript from Apple
Events**. This lets macvoice read a page through the DOM (~23 ms) instead of the Accessibility tree
(1.8–3.3 s on a heavy page). Note it also lets *any* app script your browser, so it is a real
widening of what other software can reach — everything still works without it, just slower.

---

## Using it

The menu bar icon is the whole interface:

| Icon | Meaning |
| --- | --- |
| **◉** | Live — commands run |
| **◎** | Dry-run — decisions are logged, nothing happens |
| **◌** | Muted — not listening |

Click it for **Mute**, **Live/Dry-run**, **Open at Login** and **Quit**. **⌘M** mutes from anywhere
(macvoice claims that shortcut system-wide while running, so Minimize Window is unavailable).

On a notched Mac, an island grows out of the notch: a live waveform of your voice while you speak,
then what it did. It never takes focus or intercepts clicks.

Commands act on the app that is **frontmost when you stop speaking**.

### Safety

Three tiers, all enforced in code rather than left to the model:

- **Blocked outright** and never even offered as an option: Empty Trash, Shut Down, Log Out, Reset
  All Settings, erasing disks, disabling security features.
- **Requires a spoken "confirm"**: delete, send, buy, quit, sign out, discard, install.
- **Blocked apps**: terminals, password managers, System Settings, Disk Utility, VMs, security
  tools — their screens aren't even read.

Run `./macvoice --policy` to print the whole verdict table. Password fields are never collected.
Low confidence refuses and explains rather than guessing. **⌘M** stops it listening instantly.

### Privacy

Per command, over HTTPS: **your words**, the **frontmost app's name**, and the **labels of visible
controls** (e.g. `button: Sign in`), plus open tab titles and menu command names.

Never sent: audio (recognition is on-device), screenshots, page contents, password fields, or
anything from a blocked app. Nothing is sent unless you speak.

`--no-screen` sends only your words — you keep apps, scrolling, shortcuts and typing, and lose
clicking by name. `--snapshot` prints exactly what would be sent, without sending it.

---

## Command line

The `.app` is for daily use; the CLI is for debugging.

```sh
./voice.sh [--live|--dry-run]   # run and tail the log;  ./voice.sh stop  to quit
./macvoice --text "open safari" --dry-run   # decide one command, no mic
./macvoice --repl --dry-run                 # type commands
./macvoice --snapshot            # what the screen looks like to it
./macvoice --menus               # every menu command it can see
./macvoice --tabs                # tabs per browser + automation status
./macvoice --dom                 # DOM element table + read time
./macvoice --policy             # what is blocked, confirmed, allowed
./macvoice --mic-test            # permissions, mic format, live level meter
```

Flags: `--dry-run`, `--target <App>` (pin commands to one app), `--no-screen`, `--wake <word>`,
`--silence <ms>`, `--model <id>`.

---

## How it works

```
speech ─► on-device transcription ─► [screen read starts while you talk]
                                        tabs · menus · windows · controls (DOM in a browser, else AX)
       ─► ONE Jev request, all questions answered in parallel (~300 ms)
              is_command · intent · target · tab · window · menu · app · key · site · query · destructive
       ─► code picks the answers the chosen intent needs, checks confidence, applies policy
       ─► AXPress · synthetic click · NSWorkspace · AppleScript · keystrokes · media keys
```

Two ideas do most of the work:

**Ask once, ask everything.** Extra questions cost tokens, not latency, so every question is asked
up front and the code ignores what it doesn't need.

**Narrow before asking.** A Choice over 120 on-screen elements splits probability so thin that the
correct answer scored 0.35 and was rejected. Candidates are shortlisted in code first, which put the
same answer at 1.00. The same applies to tabs and windows.

Anything the model is bad at stays in code: coordinates, counting, and writing text. Search terms
are cut from your transcript by regex and Jev only picks which span is the query.

**Source:** `main.swift` (decisions, actions, speech) · `ui.swift` (island, menu bar) ·
`task.swift` (multi-step goals) · `dom.swift` (page reading) · `windows.swift` · `menus.swift` ·
`browser.swift` (tabs, sites, search) · `profiles.swift` · `policy.swift` · `parse.swift`

## Known limits

- **No tests.** This is the biggest gap. Safety-critical logic (`policy.swift`) and the candidate
  shortlisting are verified only by hand.
- Needs the network for every command (~300 ms).
- Only sees what the Accessibility tree or DOM exposes — canvas apps and games show little.
- Windows on another Space and full-screen windows aren't reliably visible to the API.
- A single command acts on the frontmost app: "open a new tab in Brave" does not switch to Brave
  first. Within a compound command, context *is* carried between steps.
- Multi-step tasks are capped at 8 steps and are the least predictable part; single commands are
  near-deterministic.
- Safari is excluded from the DOM path and uses the Accessibility tree.
