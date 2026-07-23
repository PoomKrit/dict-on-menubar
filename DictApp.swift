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
