# Dict on Menubar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menubar app that pops out a search box; type a Thai or English word and its translation appears instantly below, powered by the built-in macOS Thai↔English dictionary — no network, no API key.

**Architecture:** Single-file Swift app compiled with `swiftc` (no Xcode project), mirroring the `mic-mute-button` reference exactly: `NSStatusItem` holds the menubar icon, clicking it toggles an `NSPopover` whose `contentViewController` hosts a search field + scrollable results text view. Translation comes from macOS's private `DictionaryServices` C API (`DCSGetActiveDictionaries` + `DCSCopyTextDefinition`), restricted to the `com.apple.dictionary.th-en.oup` Oxford Thai-English dictionary. Live lookup fires on each keystroke through a 300 ms debounce timer.

**Tech Stack:** Swift 6.3, AppKit, CoreServices (`DictionaryServices`), `swiftc` single-file compile, `build.sh` app-bundle assembly with ad-hoc codesign.

## Global Constraints

- Target platform: macOS 26.x (verified on 26.5.2); minimum practical floor macOS 12 (matches reference). One line: SF Symbols and the DCS private symbols used here exist on macOS 12+.
- Build with `swiftc` only — no `.xcodeproj`, no SwiftPM manifest. Single source file `DictApp.swift`.
- No third-party dependencies and no network calls. Translation is 100% local via `DictionaryServices`.
- Menubar-only app: `NSApp.setActivationPolicy(.accessory)` — no Dock icon, no main window.
- **CFRange lengths passed to `DCSCopyTextDefinition` MUST be UTF-16 code-unit counts (`(text as NSString).length`), NOT Swift `String.count`.** Using grapheme count silently breaks Thai lookups (Thai combining vowel/tone marks make the two differ). Copied verbatim into every lookup call.
- The DCS symbols are private and bridged via `@_silgen_name`. Exact bridge signatures are defined in Task 2 and reused unchanged.
- Bundle identifier: `com.local.dictmenubar`. Display name: `Dict on Menubar`.
- Git commits use the AI bot identity and `triggered-by: poomkrit` trailer per the repo's CLAUDE.md.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `DictApp.swift` | Entire app: DCS bridge + lookup function, `PopoverViewController` (search field + results view), `MenubarController` (status item + popover), `AppDelegate`, entry point. |
| `build.sh` | Compile `DictApp.swift`, assemble `DictApp.app`, write `Info.plist`, ad-hoc codesign. |
| `README.md` | What it is, requirements, build/run, how it works, limitations. |
| `.gitignore` | Ignore build artifacts (`DictApp`, `DictApp.app`). |

There is deliberately one source file. The reference app (`mic-mute-button`) is also single-file and this app is comparable in size; splitting would add friction to the `swiftc` build with no benefit (YAGNI).

Task order builds bottom-up: bridge/lookup first (the risky core), then UI, then wiring, then packaging. Each task ends with something runnable or independently verifiable.

---

### Task 1: Project scaffolding

**Files:**
- Create: `DictApp.swift`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: a `DictApp.swift` that compiles to an empty accessory app (proves the toolchain and activation policy before any logic is added).

- [ ] **Step 1: Create `.gitignore`**

Create `.gitignore`:

```
DictApp
DictApp.app
.DS_Store
```

- [ ] **Step 2: Create the minimal compilable app**

Create `DictApp.swift`:

```swift
// DictApp.swift
// Build: swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp
// Run:   ./DictApp

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.activate(ignoringOtherApps: true)
app.run()
```

- [ ] **Step 3: Compile to verify the toolchain**

Run: `cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar && swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp`
Expected: no output, exit code 0, a `DictApp` binary is produced. (Do not run it — with no status item it would be an invisible process; kill via Ctrl-C if you do.)

- [ ] **Step 4: Commit**

```bash
cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar
git init 2>/dev/null; git add DictApp.swift .gitignore
GIT_AUTHOR_NAME="claude-code[bot]" \
GIT_AUTHOR_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
GIT_COMMITTER_NAME="claude-code[bot]" \
GIT_COMMITTER_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
git commit -m "$(cat <<'EOF'
chore: scaffold single-file accessory app

triggered-by: poomkrit
EOF
)"
```

---

### Task 2: DCS bridge + Thai-English lookup function

This is the technical core and the highest-risk piece. It has been proven to work on the target machine during planning; this task reproduces that proof as a repeatable check.

**Files:**
- Modify: `DictApp.swift` (add the bridge and `translate` above `AppDelegate`)
- Create: `/tmp/lookup_check.swift` (throwaway verification harness, not committed)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `func translate(_ text: String) -> String?` — returns the raw definition string from the Thai-English dictionary for `text`, or `nil` if there is no entry / input is empty. Whitespace-only input returns `nil`.
  - Internal: `thaiEnglishDictionary` lazily-resolved `DCSDictionaryRef?`.

- [ ] **Step 1: Write the verification harness (proves the private API before touching the app)**

Create `/tmp/lookup_check.swift`:

```swift
import Foundation
import CoreServices

typealias DCSDictionaryRef = CFTypeRef

@_silgen_name("DCSGetActiveDictionaries")
func DCSGetActiveDictionaries() -> CFArray

@_silgen_name("DCSDictionaryGetIdentifier")
func DCSDictionaryGetIdentifier(_ dict: DCSDictionaryRef) -> CFString

@_silgen_name("DCSCopyTextDefinition")
func DCSCopyTextDefinition(_ dict: DCSDictionaryRef?, _ text: CFString, _ range: CFRange) -> Unmanaged<CFString>?

func resolveThaiEnglish() -> DCSDictionaryRef? {
    let actives = DCSGetActiveDictionaries() as [AnyObject]
    for d in actives {
        let ident = DCSDictionaryGetIdentifier(d as CFTypeRef) as String
        if ident.contains("th-en") { return d as CFTypeRef }
    }
    return nil
}

func translate(_ text: String, dict: DCSDictionaryRef?) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let ns = trimmed as NSString
    let range = CFRangeMake(0, ns.length)  // UTF-16 length — required for Thai
    guard let def = DCSCopyTextDefinition(dict, trimmed as CFString, range)?.takeRetainedValue() else {
        return nil
    }
    return def as String
}

let dict = resolveThaiEnglish()
assert(dict != nil, "th-en dictionary not active — enable it in Dictionary.app > Preferences")
for w in ["cat", "แมว", "hello", "สวัสดี", "run", "zxqwv"] {
    print("[\(w)] => \(translate(w, dict: dict).map { String($0.prefix(60)) } ?? "(nil)")")
}
```

- [ ] **Step 2: Run the harness to verify it works**

Run: `swiftc /tmp/lookup_check.swift -framework CoreServices -o /tmp/lookup_check && /tmp/lookup_check`
Expected (values may vary slightly by dictionary version, but these shapes MUST hold):
```
[cat] => cat1 | แคท | n. ...แมว...
[แมว] => แมว n. cat ...
[hello] => hello | ... | interj. ...
[สวัสดี] => สวัสดี v. to greet, to say hello ...
[run] => run | รัน | v. ...
[zxqwv] => (nil)
```
Both English→Thai and Thai→English return content; a nonsense word returns `(nil)`; **`สวัสดี` returns content** (this specific word is the regression guard for the UTF-16 range bug — if it prints `(nil)`, the `CFRange` length is wrong).

- [ ] **Step 3: Add the bridge and lookup into `DictApp.swift`**

In `DictApp.swift`, change the import line and insert the bridge + lookup between the imports and `AppDelegate`. The file's top becomes:

```swift
// DictApp.swift
// Build: swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp
// Run:   ./DictApp

import AppKit
import CoreServices

// MARK: - DictionaryServices Bridge (private API)

typealias DCSDictionaryRef = CFTypeRef

@_silgen_name("DCSGetActiveDictionaries")
func DCSGetActiveDictionaries() -> CFArray

@_silgen_name("DCSDictionaryGetIdentifier")
func DCSDictionaryGetIdentifier(_ dict: DCSDictionaryRef) -> CFString

@_silgen_name("DCSCopyTextDefinition")
func DCSCopyTextDefinition(_ dict: DCSDictionaryRef?, _ text: CFString, _ range: CFRange) -> Unmanaged<CFString>?

// MARK: - Lookup

/// The Oxford Thai-English dictionary, resolved once from the active set.
let thaiEnglishDictionary: DCSDictionaryRef? = {
    let actives = DCSGetActiveDictionaries() as [AnyObject]
    for d in actives {
        let ident = DCSDictionaryGetIdentifier(d as CFTypeRef) as String
        if ident.contains("th-en") { return d as CFTypeRef }
    }
    return nil
}()

/// Look up `text` in the Thai-English dictionary. Returns the raw definition
/// string, or nil when the input is empty/whitespace or has no entry.
func translate(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let ns = trimmed as NSString
    // CFRange length MUST be UTF-16 code units, not Swift String.count,
    // or Thai words with combining marks silently fail to resolve.
    let range = CFRangeMake(0, ns.length)
    guard let def = DCSCopyTextDefinition(thaiEnglishDictionary, trimmed as CFString, range)?.takeRetainedValue() else {
        return nil
    }
    return def as String
}
```

Leave the existing `AppDelegate` and entry point unchanged for now.

- [ ] **Step 4: Recompile the app to verify it still builds with the bridge**

Run: `cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar && swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp`
Expected: exit code 0. Warnings about `as [AnyObject]` are acceptable; there must be no errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar
git add DictApp.swift
GIT_AUTHOR_NAME="claude-code[bot]" \
GIT_AUTHOR_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
GIT_COMMITTER_NAME="claude-code[bot]" \
GIT_COMMITTER_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
git commit -m "$(cat <<'EOF'
feat: add Thai-English dictionary lookup via DictionaryServices

triggered-by: poomkrit
EOF
)"
```

---

### Task 3: Popover view controller (search field + results)

**Files:**
- Modify: `DictApp.swift` (add `PopoverViewController` between the lookup function and `AppDelegate`)

**Interfaces:**
- Consumes: `translate(_:) -> String?` from Task 2.
- Produces:
  - `final class PopoverViewController: NSViewController`
  - `var onQuit: (() -> Void)?` — called when the Quit button is clicked.
  - `func focusSearchField()` — makes the search field first responder (called by Task 4 when the popover opens).
  - Fixed popover content width: 320 pt. Results area is a fixed-height scroll view (220 pt) so the popover doesn't resize per lookup.
  - Live lookup: debounced 300 ms after the last keystroke via a `Timer`.

- [ ] **Step 1: Add `PopoverViewController`**

In `DictApp.swift`, insert immediately before `// MARK: - App Delegate` (or before `final class AppDelegate` if that marker is absent):

```swift
// MARK: - Popover View Controller

final class PopoverViewController: NSViewController, NSSearchFieldDelegate {
    var onQuit: (() -> Void)?

    private let searchField = NSSearchField()
    private let resultTextView = NSTextView()
    private let scrollView = NSScrollView()
    private var debounceTimer: Timer?

    private let contentWidth: CGFloat = 320
    private let resultsHeight: CGFloat = 220

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 0))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let innerWidth = contentWidth - 24  // minus edge insets

        // Search field
        searchField.placeholderString = "พิมพ์คำ ไทย หรือ อังกฤษ…"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.font = NSFont.systemFont(ofSize: 14)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        stack.addArrangedSubview(searchField)

        // Results scroll view + text view
        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.drawsBackground = false
        resultTextView.font = NSFont.systemFont(ofSize: 13)
        resultTextView.textContainerInset = NSSize(width: 4, height: 4)
        resultTextView.string = "พิมพ์คำเพื่อค้นหา"
        resultTextView.textColor = .secondaryLabelColor

        scrollView.documentView = resultTextView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: resultsHeight).isActive = true
        stack.addArrangedSubview(scrollView)

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        stack.addArrangedSubview(divider)

        // Quit button
        let quitBtn = NSButton(title: "Quit Dict on Menubar", target: self, action: #selector(quitClicked))
        quitBtn.bezelStyle = .roundRect
        quitBtn.setButtonType(.momentaryPushIn)
        quitBtn.font = NSFont.systemFont(ofSize: 12)
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        quitBtn.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        stack.addArrangedSubview(quitBtn)

        view.layoutSubtreeIfNeeded()
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    // Fires on every keystroke.
    func controlTextDidChange(_ obj: Notification) {
        debounceTimer?.invalidate()
        let query = searchField.stringValue
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.performLookup(query)
        }
    }

    private func performLookup(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            resultTextView.string = "พิมพ์คำเพื่อค้นหา"
            resultTextView.textColor = .secondaryLabelColor
            return
        }
        if let def = translate(trimmed) {
            resultTextView.string = def
            resultTextView.textColor = .labelColor
        } else {
            resultTextView.string = "ไม่พบคำว่า “\(trimmed)”"
            resultTextView.textColor = .secondaryLabelColor
        }
        resultTextView.scroll(NSPoint.zero)
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
```

- [ ] **Step 2: Compile to verify it builds**

Run: `cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar && swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp`
Expected: exit code 0, no errors.

- [ ] **Step 3: Commit**

```bash
cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar
git add DictApp.swift
GIT_AUTHOR_NAME="claude-code[bot]" \
GIT_AUTHOR_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
GIT_COMMITTER_NAME="claude-code[bot]" \
GIT_COMMITTER_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
git commit -m "$(cat <<'EOF'
feat: add popover UI with debounced live lookup

triggered-by: poomkrit
EOF
)"
```

---

### Task 4: Menubar controller + wire up the app

**Files:**
- Modify: `DictApp.swift` (add `MenubarController`, update `AppDelegate`)

**Interfaces:**
- Consumes: `PopoverViewController` (with `onQuit` and `focusSearchField()`) from Task 3.
- Produces:
  - `final class MenubarController: NSObject` — owns the `NSStatusItem` and `NSPopover`; icon is the `character.book.closed` SF Symbol.
  - Updated `AppDelegate` that instantiates and retains a `MenubarController`.

- [ ] **Step 1: Add `MenubarController`**

In `DictApp.swift`, insert before `// MARK: - App Delegate`:

```swift
// MARK: - Menubar Controller

final class MenubarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let popoverVC = PopoverViewController()

    override init() {
        super.init()

        popoverVC.onQuit = { NSApplication.shared.terminate(nil) }

        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "character.book.closed",
                                   accessibilityDescription: "Dictionary")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            popoverVC.focusSearchField()
        }
    }
}
```

- [ ] **Step 2: Update `AppDelegate` to own the controller**

Replace the existing `AppDelegate` class with:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubarController: MenubarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menubarController = MenubarController()
    }
}
```

- [ ] **Step 3: Compile**

Run: `cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar && swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp`
Expected: exit code 0, no errors.

- [ ] **Step 4: Manual smoke test (interactive — ask the user to run it)**

Because this puts an icon in the live menubar, the user should run it. Suggest they type in the session:
`! cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar && ./DictApp &`
Then verify by hand:
1. A book icon appears in the menubar.
2. Clicking it opens a popover with a search field already focused.
3. Typing `cat` shows a Thai definition within ~½ second.
4. Typing `แมว` shows `cat …`.
5. Typing gibberish (`zxqwv`) shows `ไม่พบคำว่า …`.
6. Clicking outside closes the popover; "Quit Dict on Menubar" exits.

To stop it: `! pkill DictApp`

- [ ] **Step 5: Commit**

```bash
cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar
git add DictApp.swift
GIT_AUTHOR_NAME="claude-code[bot]" \
GIT_AUTHOR_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
GIT_COMMITTER_NAME="claude-code[bot]" \
GIT_COMMITTER_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
git commit -m "$(cat <<'EOF'
feat: add menubar status item and wire up popover

triggered-by: poomkrit
EOF
)"
```

---

### Task 5: Build script (app bundle + ad-hoc sign)

**Files:**
- Create: `build.sh`

**Interfaces:**
- Consumes: `DictApp.swift`.
- Produces: `DictApp.app` — a double-clickable, ad-hoc-signed bundle with `Info.plist`.

- [ ] **Step 1: Create `build.sh`**

Create `build.sh` (adapted from the reference; note the extra `CoreServices` framework and no icon file — the menubar uses an SF Symbol, and no `.icns` exists yet):

```bash
#!/bin/bash
set -e

APP="DictApp"
BUNDLE="${APP}.app"

echo "Compiling..."
swiftc "${APP}.swift" -framework AppKit -framework CoreServices -o "${APP}"

echo "Building app bundle..."
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${APP}" "${BUNDLE}/Contents/MacOS/"

cat > "${BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DictApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.dictmenubar</string>
    <key>CFBundleName</key>
    <string>Dict on Menubar</string>
    <key>CFBundleDisplayName</key>
    <string>Dict on Menubar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS doesn't block the unsigned binary
codesign --sign - --force "${BUNDLE}"

echo "Done! DictApp.app is ready."
echo "You can drag it to /Applications or double-click it from Finder."
```

Note: `LSUIElement=true` is the Info.plist equivalent of `.accessory` — it keeps the bundled app out of the Dock even if launched from Finder.

- [ ] **Step 2: Run the build script**

Run: `cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar && chmod +x build.sh && ./build.sh`
Expected output ends with `Done! DictApp.app is ready.` and no `codesign` error.

- [ ] **Step 3: Verify the bundle signature and structure**

Run: `cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar && codesign --verify --verbose DictApp.app && ls DictApp.app/Contents/MacOS DictApp.app/Contents/Info.plist`
Expected: `DictApp.app: valid on disk` / `satisfies its Designated Requirement`, and the `MacOS/DictApp` executable + `Info.plist` are listed.

- [ ] **Step 4: Commit**

```bash
cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar
git add build.sh
GIT_AUTHOR_NAME="claude-code[bot]" \
GIT_AUTHOR_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
GIT_COMMITTER_NAME="claude-code[bot]" \
GIT_COMMITTER_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
git commit -m "$(cat <<'EOF'
build: add app-bundle build script with ad-hoc signing

triggered-by: poomkrit
EOF
)"
```

---

### Task 6: README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: user-facing documentation.

- [ ] **Step 1: Create `README.md`**

Create `README.md`:

```markdown
# Dict on Menubar

A minimal native macOS menubar app for instant Thai↔English translation. Click
the menubar icon, type a word in Thai or English, and its translation appears
immediately — powered entirely by the dictionary built into macOS. No network,
no API key, no Xcode.

## Features

- Lives in the menubar — no Dock icon, no window
- Click the icon to open a search popover (search field is auto-focused)
- Type Thai **or** English — bidirectional lookup
- Live results with a 300 ms debounce as you type
- Uses the built-in Oxford Thai-English dictionary (`com.apple.dictionary.th-en.oup`)
- Fully offline

## Requirements

- macOS 12 or later
- Xcode Command Line Tools (`xcode-select --install`)
- The **Thai - English** dictionary must be enabled in **Dictionary.app →
  Settings…** (checkbox next to "Thai - English"). If it is not enabled, no
  results will appear.

## Build & Run

```bash
chmod +x build.sh
./build.sh
```

This compiles `DictApp.swift`, assembles `DictApp.app` with an `Info.plist`,
ad-hoc signs it, and prints the path. Drag `DictApp.app` to `/Applications` or
double-click it from Finder.

To compile and run without a bundle:

```bash
swiftc DictApp.swift -framework AppKit -framework CoreServices -o DictApp
./DictApp
```

## Files

| File | Description |
|------|-------------|
| `DictApp.swift` | Full app source (DictionaryServices + AppKit) |
| `build.sh` | Builds `.app` bundle, writes `Info.plist`, ad-hoc signs |

## How It Works

- **DictionaryServices** (a private C API bridged via `@_silgen_name`) is used
  to enumerate active dictionaries, find the Thai-English one, and call
  `DCSCopyTextDefinition` to fetch definitions locally.
- **NSStatusItem** places the app in the menubar with an SF Symbol icon.
- **NSPopover** shows a floating panel on click — search field on top,
  scrollable results below; closes on click-outside.

## Known Limitations

- Results are the dictionary's raw text (headword, pronunciation, senses,
  phrases) shown as-is, not reformatted.
- Depends on Apple's private `DictionaryServices` symbols. These have been
  stable for many macOS releases but are not a public API.
- Only the Thai-English dictionary is queried; other enabled dictionaries are
  ignored by design.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/krittanon.kuljittisuteeporn/github/dict-on-menubar
git add README.md
GIT_AUTHOR_NAME="claude-code[bot]" \
GIT_AUTHOR_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
GIT_COMMITTER_NAME="claude-code[bot]" \
GIT_COMMITTER_EMAIL="claude-code[bot]@users.noreply.anthropic.com" \
git commit -m "$(cat <<'EOF'
docs: add README

triggered-by: poomkrit
EOF
)"
```

---

## Self-Review

**1. Spec coverage** (the request: menubar app, click → pop-out, enter Thai or English, translation shows immediately in the menubar, like `mic-mute-button`):
- Menubar app, click → pop-out → Task 4 (`NSStatusItem` + `NSPopover`).
- Enter Thai or English → Task 3 (single `NSSearchField`, bidirectional `translate`).
- Translation shows immediately → Task 3 (300 ms debounced live lookup).
- Same style as `mic-mute-button` → single-file `swiftc` build, `NSStatusItem`/`NSPopover`, `build.sh` bundle — Tasks 1–5.
- No gaps found.

**2. Placeholder scan:** No TBD/TODO/"handle errors appropriately"/"similar to Task N". Every code step contains complete code; every command lists expected output. The one interactive step (Task 4 Step 4) is explicitly delegated to the user because it manipulates the live menubar.

**3. Type consistency:**
- `translate(_ text: String) -> String?` — defined Task 2, called Task 3. Consistent.
- `PopoverViewController` API (`onQuit`, `focusSearchField()`) — defined Task 3, consumed Task 4. Consistent.
- `MenubarController` — defined Task 4, consumed by `AppDelegate` in Task 4. Consistent.
- DCS bridge signatures identical between the Task 2 harness and the in-app version. Consistent.
- Bundle identifier `com.local.dictmenubar` and executable `DictApp` match between `build.sh` and `Info.plist`. Consistent.

Verified once during planning on macOS 26.5.2 / Swift 6.3.3: the private DCS bridge resolves `com.apple.dictionary.th-en.oup`, bidirectional lookup works, the UTF-16 range fix is required for Thai, and `character.book.closed` is a valid SF Symbol.
```
