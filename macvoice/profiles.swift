// Chrome/Brave profiles. "Open Chrome in work profile" needs a verb that knows profiles exist —
// understanding the sentence was never the problem.
//
// Two names matter and they are different: the profile's own name in Preferences ("Your Chrome")
// and the Google account name Chrome puts in the window title ("Alex Kim", "alex"). Users say the
// account name, so both are matched.
import AppKit

struct BrowserProfile {
  let app: String
  let dir: String          // --profile-directory value, e.g. "Profile 1"
  let name: String         // profile name from Preferences
  let account: String      // account/user name, often what the user actually says
  var spoken: String { account.isEmpty ? name : account }
}

private let profileRoots = [
  "Google Chrome": "Google/Chrome",
  "Brave Browser": "BraveSoftware/Brave-Browser",
  "Microsoft Edge": "Microsoft Edge",
]

func browserProfiles(_ app: String) -> [BrowserProfile] {
  guard let sub = profileRoots[app] else { return [] }
  let base = NSHomeDirectory() + "/Library/Application Support/" + sub
  guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
  var out: [BrowserProfile] = []
  for d in dirs where d == "Default" || d.hasPrefix("Profile ") {
    let prefs = base + "/" + d + "/Preferences"
    guard let data = FileManager.default.contents(atPath: prefs),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    let p = j["profile"] as? [String: Any]
    let name = (p?["name"] as? String) ?? d
    // The signed-in account's display name lives under account_info.
    let account = ((j["account_info"] as? [[String: Any]])?.first?["full_name"] as? String)
      ?? ((j["account_info"] as? [[String: Any]])?.first?["given_name"] as? String) ?? ""
    out.append(BrowserProfile(app: app, dir: d, name: name, account: account))
  }
  return out
}

/// Matches what the user said against profile names, account names, and live window titles.
func matchProfile(_ said: String, _ app: String) -> BrowserProfile? {
  let hint = said.lowercased()
  let profiles = browserProfiles(app)
  guard !profiles.isEmpty else { return nil }
  for p in profiles {
    for candidate in [p.account, p.name] where !candidate.isEmpty {
      let c = candidate.lowercased()
      if hint.contains(c) || c.split(separator: " ").contains(where: { hint.contains($0.lowercased()) }) {
        return p
      }
    }
  }
  return nil
}

/// A window of this browser already open in the named profile. Chrome puts the account name at the
/// end of the title, so an existing window can be reused instead of launching another one.
func windowForProfile(_ p: BrowserProfile) -> Win? {
  let needle = p.spoken.lowercased()
  guard !needle.isEmpty else { return nil }
  return allWindows().first {
    $0.app == p.app && $0.title.lowercased().contains(needle)
  }
}

/// Focus an existing window of that profile, or launch a new one bound to it.
@discardableResult
func openProfile(_ p: BrowserProfile) -> Bool {
  if let w = windowForProfile(p) { focusWindow(w); return true }
  guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleFor(p.app) ?? "") else { return false }
  let c = NSWorkspace.OpenConfiguration()
  c.activates = true
  c.createsNewApplicationInstance = false
  c.arguments = ["--profile-directory=\(p.dir)"]
  NSWorkspace.shared.openApplication(at: url, configuration: c) { _, _ in }
  return true
}

private func bundleFor(_ app: String) -> String? {
  ["Google Chrome": "com.google.Chrome",
   "Brave Browser": "com.brave.Browser",
   "Microsoft Edge": "com.microsoft.edgemac"][app]
}
