// What voice control is allowed to touch on this Mac.
//
// The threat is not a malicious model — Jev can only return options this code offered. It is a
// MIS-HEARD word that happens to be a valid command. "Move to Trash" is one menu item away in
// Finder, and we now expose ~180 menu commands per app. A sibling project (timpratim/macbrow) had
// an early version move every file on the Desktop when asked to "clean up my desktop"; this file
// exists so that class of accident cannot happen here.
//
// Enforced in two places, deliberately:
//   1. when the candidate list is built — a blocked command is never offered to the model at all
//   2. immediately before execution — on the final resolved action, whatever route produced it
import Foundation

enum Verdict {
  case allow
  case confirm(String)   // reason, spoken back to the user
  case block(String)     // reason, refused outright
}

// MARK: apps

/// Never read the screen of these, and never drive them. Password managers and terminals, because
/// a mis-heard click there is unrecoverable; System Settings because it reconfigures the machine.
let blockedBundlePrefixes = [
  "com.apple.keychainaccess", "com.apple.Passwords", "com.1password", "com.agilebits",
  "com.bitwarden", "com.lastpass", "com.dashlane", "in.sinew.Enpass",
  "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp",
  "net.kovidgoyal.kitty", "io.alacritty", "co.zeit.hyper",
  "com.apple.systempreferences", "com.apple.Settings",
  "com.apple.DiskUtility", "com.apple.ActivityMonitor", "com.apple.ScriptEditor2",
  "com.apple.Automator", "com.apple.Console", "com.apple.MigrationAssistant",
  "com.apple.InstallAssistant", "com.apple.ScreenSharing",
  "com.docker", "dev.orbstack", "com.utmapp", "com.parallels", "com.vmware",
  "at.obdev.littlesnitch", "com.objective-see.lulu",
]
func isDenied(_ bundleId: String) -> Bool {
  blockedBundlePrefixes.contains { bundleId.hasPrefix($0) }
}

/// Matched against an app NAME, for "open <app>" where we have no bundle id yet.
private let blockedAppNames: Set<String> = [
  "system settings", "system preferences", "terminal", "iterm", "iterm2", "ghostty", "warp",
  "kitty", "alacritty", "hyper", "keychain access", "passwords", "1password", "bitwarden",
  "lastpass", "dashlane", "enpass", "disk utility", "activity monitor", "script editor",
  "automator", "console", "migration assistant", "screen sharing", "little snitch", "lulu",
]

// MARK: command text

private func rx(_ p: String) -> NSRegularExpression {
  try! NSRegularExpression(pattern: p, options: .caseInsensitive)
}
private func hits(_ re: NSRegularExpression, _ s: String) -> Bool {
  re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// Refused outright. No confirmation offered, because there is no safe way to mis-hear these.
private let blockedPatterns: [(NSRegularExpression, String)] = [
  (rx("\\b(erase|reformat|format)\\b.*\\b(disk|volume|drive|mac|everything)\\b"), "erases a disk"),
  (rx("\\berase (all content|assistant)"), "erases the Mac"),
  (rx("\\b(shut ?down|restart|reboot|log ?out|sign ?out of (this )?mac|sleep now)\\b"), "ends the session"),
  (rx("\\bempty (the )?(trash|bin)\\b"), "permanently deletes files"),
  (rx("\\b(reset|restore)\\b.*\\b(settings|defaults|factory|device|mac)\\b"), "resets the machine"),
  (rx("\\buninstall\\b"), "uninstalls software"),
  (rx("\\b(disable|turn off)\\b.*\\b(firewall|filevault|gatekeeper|sip|protection)\\b"), "weakens security"),
  (rx("\\bkeychain\\b|\\bpasswords?\\b.*\\b(show|reveal|copy|export)\\b"), "touches stored passwords"),
  (rx("\\b(add|remove|change)\\b.*\\b(admin|administrator|sudo|root)\\b"), "changes privileges"),
]

/// Allowed, but only after the user says "confirm". Hard or slow to undo.
private let confirmPatterns: [(NSRegularExpression, String)] = [
  (rx("\\b(delete|remove|trash|move to (the )?(trash|bin)|erase)\\b"), "deletes something"),
  (rx("\\b(send|submit|post|publish|share|reply|forward)\\b"), "sends something"),
  (rx("\\b(buy|purchase|order|checkout|check out|pay|place order|subscribe)\\b"), "spends money"),
  (rx("\\b(quit|close all|force quit)\\b"), "quits an app"),
  (rx("\\bsign ?out|log ?out\\b"), "signs you out"),
  (rx("\\b(discard|revert|reset)\\b"), "discards work"),
  (rx("\\b(unsubscribe|deactivate|cancel (my )?(account|subscription|plan))\\b"), "cancels an account"),
  (rx("\\bmove to\\b.*\\bfolder\\b"), "moves files"),
  (rx("\\b(install|update|upgrade)\\b"), "installs software"),
]

// MARK: the checks

/// Is this a command we will never run, whatever the model thought?
func policyBlocks(_ text: String) -> String? {
  for (re, why) in blockedPatterns where hits(re, text) { return why }
  return nil
}

/// Does it need a spoken "confirm" first?
func policyNeedsConfirm(_ text: String) -> String? {
  for (re, why) in confirmPatterns where hits(re, text) { return why }
  return nil
}

/// The single decision point. `subject` is what will be acted on (a menu path, a button label,
/// an app name); `utterance` is what the user actually said. Both are checked: the user may say
/// something harmless that resolves to a dangerous control, or vice versa.
func judge(subject: String, utterance: String, appName: String = "") -> Verdict {
  if !appName.isEmpty, blockedAppNames.contains(appName.lowercased()) {
    return .block("\(appName) is not voice-controllable")
  }
  for text in [subject, utterance] {
    if let why = policyBlocks(text) { return .block(why) }
  }
  for text in [subject, utterance] {
    if let why = policyNeedsConfirm(text) { return .confirm(why) }
  }
  return .allow
}

/// Applied when the menu list is built, so a blocked command is never even offered as an option.
/// Filtering the candidate list is stronger than checking afterwards: the model cannot pick what
/// it was never shown.
func policyAllowsMenu(_ path: String) -> Bool {
  policyBlocks(path) == nil
}

/// Opening an app is normally harmless; these are the exceptions.
func policyAllowsOpening(_ appName: String) -> Bool {
  !blockedAppNames.contains(appName.lowercased())
}
