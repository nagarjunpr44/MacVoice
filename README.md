# macvoice

Control your Mac by talking to it. Say *"open chrome"*, *"make the text bigger"*, *"go to the wikipedia
tab"* — it clicks, opens, scrolls, types and runs menu commands.

Speech is recognised **on-device**. Each utterance becomes **one** request to
[TypeSafe Jev](https://docs.typesafe.ai), a System One model that returns a typed decision with
probabilities instead of generated text. Jev only ever *chooses* from options this app supplies —
it cannot invent an action or write text — and your code decides whether that choice is confident
enough to act on.

Typical command: **~300 ms** of model time, about **$0.0002**.

---

## What it can do

| Say | What happens |
| --- | --- |
| "open chrome", "open safari" | Launches or switches to the app |
| "click sign in", "tick remember me" | Clicks any labelled button, link, checkbox or tab on screen |
| "make the text bigger", "open a private window" | Runs the app's own **menu commands** — no keyboard shortcut needed |
| "go to the wikipedia tab" | Switches to any open tab, in **any window of any browser** |
| "search for best ramen in tokyo", "search youtube for lofi" | Opens a search in a new tab |
| "scroll down", "go to the bottom" | Scrolls the focused window |
| "copy this", "undo", "new tab", "go back" | 24 keyboard shortcuts |
| "type hello world" | Types into the focused field |

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
| **Automation** | Read browser tabs, open searches | …→ Automation → macvoice |

`./grant.sh` resets the Accessibility entry and opens the right pane if it gets stuck.

---

## Using it

The menu bar icon is the whole interface:

| Icon | Meaning |
| --- | --- |
| **◉** | Live — commands run |
| **◎** | Dry-run — decisions are logged, nothing happens |
| **◌** | Muted — not listening |

Click it for **Mute**, **Live/Dry-run**, **Open at Login** and **Quit**. **⌘M** mutes from anywhere.

On a notched Mac, an island grows out of the notch: a live waveform of your voice while you speak,
then what it did. It never takes focus or intercepts clicks.

Commands act on the app that is **frontmost when you stop speaking**.

### Safety

- **Dry-run first** if you're unsure: menu bar → Dry-run.
- Anything destructive (delete, send, pay, quit, sign out…) asks you to say **"confirm"** — driven by
  a word list in code, not by the model's judgement alone.
- Low confidence refuses and explains instead of guessing.
- Password fields are never read. Keychain, 1Password, Bitwarden, LastPass and terminals are on a
  deny list: their screens aren't read at all.
- **⌘M** stops it listening instantly.

### Privacy

Per command, over HTTPS: **your words**, the **frontmost app's name**, and the **labels of visible
controls** (e.g. `button: Sign in`), plus open tab titles and menu command names.

Never sent: audio (recognition is on-device), screenshots, page contents, password fields, or
anything from a deny-listed app. Nothing is sent unless you speak.

Run with `--no-screen` to send only your words — you keep apps, scrolling, shortcuts and typing, and
lose clicking by name. `--snapshot` prints exactly what would be sent, without sending it.

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
./macvoice --mic-test            # permissions, mic format, live level meter
```

Flags: `--dry-run`, `--target <App>` (pin commands to one app), `--no-screen`, `--wake <word>`
(require a wake word), `--silence <ms>`, `--model <id>`.

---

## How it works

```
speech ─► on-device transcription ─► [screen read starts while you talk]
                                          tabs · menu commands · on-screen controls
       ─► ONE Jev request, all questions answered in parallel (~300 ms)
              is_command · intent · target · tab · menu · app · key · scroll · query · destructive
       ─► code picks the answers the chosen intent needs, checks confidence
       ─► AXPress · synthetic click · NSWorkspace · AppleScript · keystrokes
```

Extra questions cost tokens, not latency, so everything is asked at once and the code ignores what
it doesn't need. Anything the model is bad at — coordinates, counting, writing text — stays in code:
search terms are cut from your transcript by regex, and Jev only picks which span is the query.

**Source:** `main.swift` (decisions, actions, speech) · `ui.swift` (island, menu bar) ·
`menus.swift` (menu walker) · `browser.swift` (tabs, search)

## Known limits

- Needs the network for every command (~300 ms).
- Only sees what the Accessibility tree exposes — canvas apps and games show little.
- Windows on another Space and full-screen windows aren't reliably visible to the API.
- One action per utterance; no multi-step planning.
- **⌘M** is claimed system-wide while running, so Minimize Window is unavailable.
